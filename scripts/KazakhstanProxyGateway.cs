using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace MailanZapret
{
    public sealed class UpstreamProxy
    {
        public string Host { get; set; }
        public int Port { get; set; }
        public string Username { get; set; }
        public string Password { get; set; }
    }

    public sealed class LocalSocksGateway
    {
        private const int HeaderLimit = 32768;
        private readonly TcpListener listener;
        private readonly UpstreamProxy[] upstreams;
        private readonly string[] allowedDomains;
        private readonly string pacPath;
        private readonly byte[] pacBytes;
        private readonly string diagnosticLogPath;
        private readonly object diagnosticLogLock = new object();
        private volatile bool running;

        public LocalSocksGateway(
            int listenPort,
            UpstreamProxy[] configuredUpstreams,
            string[] configuredDomains,
            string configuredPacPath,
            string pacContent,
            string configuredDiagnosticLogPath)
        {
            if (configuredUpstreams == null || configuredUpstreams.Length == 0)
            {
                throw new ArgumentException("At least one upstream SOCKS5 proxy is required.");
            }
            if (configuredDomains == null || configuredDomains.Length == 0)
            {
                throw new ArgumentException("At least one allowed domain is required.");
            }

            listener = new TcpListener(IPAddress.Loopback, listenPort);
            upstreams = configuredUpstreams;
            allowedDomains = configuredDomains;
            pacPath = configuredPacPath;
            pacBytes = Encoding.UTF8.GetBytes(pacContent);
            diagnosticLogPath = configuredDiagnosticLogPath;
        }

        public void Start()
        {
            listener.Start(64);
            running = true;
        }

        public void Run(int parentPid, string stopFilePath)
        {
            if (!running)
            {
                throw new InvalidOperationException("The gateway has not been started.");
            }

            while (running && ParentIsRunning(parentPid) && !File.Exists(stopFilePath))
            {
                if (!listener.Pending())
                {
                    Thread.Sleep(100);
                    continue;
                }

                TcpClient client = null;
                try
                {
                    client = listener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(HandleClient, client);
                }
                catch
                {
                    if (client != null)
                    {
                        client.Close();
                    }
                    if (!running)
                    {
                        break;
                    }
                }
            }

            Stop();
        }

        public void Stop()
        {
            running = false;
            try
            {
                listener.Stop();
            }
            catch
            {
            }
        }

        private void HandleClient(object state)
        {
            TcpClient client = (TcpClient)state;
            TcpClient upstream = null;
            string destination = "unknown";
            try
            {
                client.NoDelay = true;
                NetworkStream clientStream = client.GetStream();
                clientStream.ReadTimeout = 30000;
                byte[] headerBytes = ReadHeader(clientStream);
                string header = Encoding.ASCII.GetString(headerBytes);
                string[] lines = header.Split(new[] { "\r\n" }, StringSplitOptions.None);
                string[] request = lines[0].Split(new[] { ' ' }, 3);
                if (request.Length != 3)
                {
                    SendError(clientStream, 400, "Malformed proxy request.");
                    return;
                }

                if (IsPacRequest(request[0], request[1]))
                {
                    Log("PAC served");
                    SendPac(clientStream);
                    return;
                }

                string host;
                int port;
                bool isConnect = string.Equals(request[0], "CONNECT", StringComparison.OrdinalIgnoreCase);
                if (isConnect)
                {
                    ParseHostAndPort(request[1], 443, out host, out port);
                }
                else
                {
                    Uri requestUri;
                    if (!Uri.TryCreate(request[1], UriKind.Absolute, out requestUri))
                    {
                        SendError(clientStream, 400, "Only absolute HTTP proxy requests are supported.");
                        return;
                    }
                    host = requestUri.Host;
                    port = requestUri.Port;
                }
                destination = host + ":" + port.ToString(CultureInfo.InvariantCulture);
                Log("REQUEST " + destination);

                if (!IsAllowedHost(host))
                {
                    Log("DENY " + destination);
                    SendError(clientStream, 403, "This local proxy is limited to configured domains.");
                    return;
                }

                upstream = ConnectThroughSocks(host, port);
                Log("CONNECTED " + destination);
                NetworkStream upstreamStream = upstream.GetStream();
                upstreamStream.ReadTimeout = 30000;

                if (isConnect)
                {
                    SendText(clientStream, "HTTP/1.1 200 Connection Established\r\nProxy-Agent: Mailan-Zapret\r\n\r\n");
                }
                else
                {
                    byte[] forwardedHeader = BuildForwardedHttpHeader(request, lines);
                    upstreamStream.Write(forwardedHeader, 0, forwardedHeader.Length);
                    upstreamStream.Flush();
                }

                Relay(clientStream, upstreamStream);
            }
            catch (Exception error)
            {
                Log("ERROR " + destination + " " + error.GetType().Name + " " + SanitizeLogText(error.GetBaseException().Message));
                try
                {
                    SendError(client.GetStream(), 502, "Unable to reach the upstream proxy.");
                }
                catch
                {
                }
            }
            finally
            {
                if (upstream != null)
                {
                    upstream.Close();
                }
                client.Close();
            }
        }

        private void Log(string message)
        {
            if (string.IsNullOrWhiteSpace(diagnosticLogPath))
            {
                return;
            }

            try
            {
                lock (diagnosticLogLock)
                {
                    File.AppendAllText(
                        diagnosticLogPath,
                        DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + " " + message + Environment.NewLine,
                        Encoding.UTF8);
                }
            }
            catch
            {
            }
        }

        private bool IsPacRequest(string method, string target)
        {
            if (!string.Equals(method, "GET", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            Uri uri;
            string path = Uri.TryCreate(target, UriKind.Absolute, out uri) ? uri.AbsolutePath : target;
            return string.Equals(path, pacPath, StringComparison.Ordinal);
        }

        private void SendPac(NetworkStream stream)
        {
            string headers = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/x-ns-proxy-autoconfig; charset=utf-8\r\n" +
                "Cache-Control: no-store\r\n" +
                "Content-Length: " + pacBytes.Length.ToString(CultureInfo.InvariantCulture) + "\r\n" +
                "Connection: close\r\n\r\n";
            SendText(stream, headers);
            stream.Write(pacBytes, 0, pacBytes.Length);
            stream.Flush();
        }

        private TcpClient ConnectThroughSocks(string destinationHost, int destinationPort)
        {
            Exception lastError = null;
            for (int attempt = 0; attempt < 2; attempt++)
            {
                for (int offset = 0; offset < upstreams.Length; offset++)
                {
                    UpstreamProxy upstream = upstreams[offset];
                    TcpClient socket = null;
                    try
                    {
                        socket = ConnectTcp(upstream.Host, upstream.Port);
                        socket.NoDelay = true;
                        NetworkStream stream = socket.GetStream();
                        stream.ReadTimeout = 15000;
                        NegotiateSocks5(stream, upstream, destinationHost, destinationPort);
                        return socket;
                    }
                    catch (Exception error)
                    {
                        lastError = error;
                        if (socket != null)
                        {
                            socket.Close();
                        }
                    }
                }

                if (attempt == 0)
                {
                    Thread.Sleep(250);
                }
            }

            throw new IOException("All configured upstream SOCKS5 proxies failed.", lastError);
        }

        private static TcpClient ConnectTcp(string host, int port)
        {
            TcpClient socket = new TcpClient();
            IAsyncResult result = socket.BeginConnect(host, port, null, null);
            try
            {
                if (!result.AsyncWaitHandle.WaitOne(TimeSpan.FromSeconds(12)))
                {
                    throw new TimeoutException("TCP connection timed out.");
                }
                socket.EndConnect(result);
                return socket;
            }
            catch
            {
                socket.Close();
                throw;
            }
            finally
            {
                result.AsyncWaitHandle.Close();
            }
        }

        private static void NegotiateSocks5(NetworkStream stream, UpstreamProxy upstream, string destinationHost, int destinationPort)
        {
            bool hasCredentials = !string.IsNullOrEmpty(upstream.Username) || !string.IsNullOrEmpty(upstream.Password);
            byte[] greeting = hasCredentials ? new byte[] { 5, 2, 0, 2 } : new byte[] { 5, 1, 0 };
            stream.Write(greeting, 0, greeting.Length);
            byte[] methodResponse = ReadExact(stream, 2);
            if (methodResponse[0] != 5 || methodResponse[1] == 255)
            {
                throw new IOException("The SOCKS5 server rejected authentication methods.");
            }
            if (methodResponse[1] == 2)
            {
                AuthenticateSocks5(stream, upstream.Username, upstream.Password);
            }
            else if (methodResponse[1] != 0)
            {
                throw new IOException("The SOCKS5 server selected an unsupported authentication method.");
            }

            string asciiHost = new IdnMapping().GetAscii(destinationHost);
            byte[] hostBytes = Encoding.ASCII.GetBytes(asciiHost);
            if (hostBytes.Length == 0 || hostBytes.Length > 255)
            {
                throw new IOException("The destination host is invalid for SOCKS5.");
            }
            if (destinationPort < 1 || destinationPort > 65535)
            {
                throw new IOException("The destination port is invalid.");
            }

            byte[] request = new byte[7 + hostBytes.Length];
            request[0] = 5;
            request[1] = 1;
            request[2] = 0;
            request[3] = 3;
            request[4] = (byte)hostBytes.Length;
            Buffer.BlockCopy(hostBytes, 0, request, 5, hostBytes.Length);
            request[5 + hostBytes.Length] = (byte)(destinationPort >> 8);
            request[6 + hostBytes.Length] = (byte)destinationPort;
            stream.Write(request, 0, request.Length);

            byte[] response = ReadExact(stream, 4);
            if (response[0] != 5 || response[1] != 0)
            {
                throw new IOException("The SOCKS5 server rejected the destination connection.");
            }
            int addressBytes;
            if (response[3] == 1)
            {
                addressBytes = 4;
            }
            else if (response[3] == 4)
            {
                addressBytes = 16;
            }
            else if (response[3] == 3)
            {
                addressBytes = ReadExact(stream, 1)[0];
            }
            else
            {
                throw new IOException("The SOCKS5 server returned an invalid address type.");
            }
            ReadExact(stream, addressBytes + 2);
        }

        private static void AuthenticateSocks5(NetworkStream stream, string username, string password)
        {
            byte[] userBytes = Encoding.UTF8.GetBytes(username ?? string.Empty);
            byte[] passwordBytes = Encoding.UTF8.GetBytes(password ?? string.Empty);
            if (userBytes.Length == 0 || userBytes.Length > 255 || passwordBytes.Length > 255)
            {
                throw new IOException("The SOCKS5 username or password is invalid.");
            }

            byte[] request = new byte[3 + userBytes.Length + passwordBytes.Length];
            request[0] = 1;
            request[1] = (byte)userBytes.Length;
            Buffer.BlockCopy(userBytes, 0, request, 2, userBytes.Length);
            request[2 + userBytes.Length] = (byte)passwordBytes.Length;
            Buffer.BlockCopy(passwordBytes, 0, request, 3 + userBytes.Length, passwordBytes.Length);
            stream.Write(request, 0, request.Length);
            byte[] response = ReadExact(stream, 2);
            if (response[0] != 1 || response[1] != 0)
            {
                throw new IOException("SOCKS5 username/password authentication failed.");
            }
        }

        private static void Relay(NetworkStream clientStream, NetworkStream upstreamStream)
        {
            Task clientToUpstream = clientStream.CopyToAsync(upstreamStream);
            Task upstreamToClient = upstreamStream.CopyToAsync(clientStream);
            Task.WaitAny(clientToUpstream, upstreamToClient);
        }

        private bool IsAllowedHost(string host)
        {
            string normalizedHost = (host ?? string.Empty).TrimEnd('.').ToLowerInvariant();
            foreach (string domain in allowedDomains)
            {
                string normalizedDomain = domain.TrimEnd('.').ToLowerInvariant();
                if (normalizedHost == normalizedDomain || normalizedHost.EndsWith("." + normalizedDomain, StringComparison.Ordinal))
                {
                    return true;
                }
            }
            return false;
        }

        private static byte[] BuildForwardedHttpHeader(string[] request, string[] lines)
        {
            Uri uri = new Uri(request[1]);
            StringBuilder builder = new StringBuilder();
            builder.Append(request[0]).Append(' ').Append(uri.PathAndQuery).Append(' ').Append(request[2]).Append("\r\n");
            for (int index = 1; index < lines.Length; index++)
            {
                string line = lines[index];
                if (line.Length == 0)
                {
                    break;
                }
                if (line.StartsWith("Proxy-Connection:", StringComparison.OrdinalIgnoreCase) ||
                    line.StartsWith("Proxy-Authorization:", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                builder.Append(line).Append("\r\n");
            }
            builder.Append("\r\n");
            return Encoding.ASCII.GetBytes(builder.ToString());
        }

        private static void ParseHostAndPort(string value, int defaultPort, out string host, out int port)
        {
            Uri uri;
            if (Uri.TryCreate("tcp://" + value, UriKind.Absolute, out uri))
            {
                host = uri.Host;
                port = uri.IsDefaultPort ? defaultPort : uri.Port;
                return;
            }

            host = value;
            port = defaultPort;
        }

        private static byte[] ReadHeader(NetworkStream stream)
        {
            MemoryStream buffer = new MemoryStream();
            int previous3 = -1;
            int previous2 = -1;
            int previous1 = -1;
            while (buffer.Length < HeaderLimit)
            {
                int value = stream.ReadByte();
                if (value < 0)
                {
                    throw new EndOfStreamException("The proxy client closed the connection before sending a request.");
                }
                buffer.WriteByte((byte)value);
                if (previous3 == '\r' && previous2 == '\n' && previous1 == '\r' && value == '\n')
                {
                    return buffer.ToArray();
                }
                previous3 = previous2;
                previous2 = previous1;
                previous1 = value;
            }
            throw new IOException("The proxy request header is too large.");
        }

        private static byte[] ReadExact(NetworkStream stream, int length)
        {
            byte[] buffer = new byte[length];
            int offset = 0;
            while (offset < length)
            {
                int received = stream.Read(buffer, offset, length - offset);
                if (received <= 0)
                {
                    throw new EndOfStreamException("The SOCKS5 server closed the connection unexpectedly.");
                }
                offset += received;
            }
            return buffer;
        }

        private static void SendText(NetworkStream stream, string value)
        {
            byte[] bytes = Encoding.ASCII.GetBytes(value);
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush();
        }

        private static string SanitizeLogText(string value)
        {
            if (string.IsNullOrEmpty(value))
            {
                return "unknown";
            }

            string sanitized = value.Replace('\r', ' ').Replace('\n', ' ').Trim();
            return sanitized.Length > 160 ? sanitized.Substring(0, 160) : sanitized;
        }

        private static void SendError(NetworkStream stream, int status, string message)
        {
            SendText(stream, "HTTP/1.1 " + status.ToString(CultureInfo.InvariantCulture) + " " + message + "\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        }

        private static bool ParentIsRunning(int parentPid)
        {
            if (parentPid <= 0)
            {
                return true;
            }
            try
            {
                Process process = Process.GetProcessById(parentPid);
                return !process.HasExited;
            }
            catch
            {
                return false;
            }
        }
    }
}
