using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading.Tasks;

namespace Shuangji.Common
{
    public static class HttpUtil
    {
        public static string Get(string url, int timeoutMs = 5000)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "GET";
            req.Timeout = timeoutMs;
            req.ReadWriteTimeout = timeoutMs;
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                return sr.ReadToEnd();
        }

        public static string PostJson(string url, string json, int timeoutMs = 8000)
        {
            var bytes = Encoding.UTF8.GetBytes(json ?? "{}");
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "POST";
            req.ContentType = "application/json; charset=utf-8";
            req.Timeout = timeoutMs;
            req.ReadWriteTimeout = timeoutMs;
            req.ContentLength = bytes.Length;
            using (var s = req.GetRequestStream())
                s.Write(bytes, 0, bytes.Length);
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                return sr.ReadToEnd();
        }

        public static async Task WriteTextAsync(HttpListenerResponse resp, string text, int code = 200, string contentType = "application/json; charset=utf-8")
        {
            var buf = Encoding.UTF8.GetBytes(text ?? "");
            resp.StatusCode = code;
            resp.ContentType = contentType;
            resp.ContentLength64 = buf.Length;
            await resp.OutputStream.WriteAsync(buf, 0, buf.Length);
            resp.OutputStream.Close();
        }

        public static string ReadBody(HttpListenerRequest req)
        {
            if (!req.HasEntityBody) return "";
            using (var sr = new StreamReader(req.InputStream, req.ContentEncoding ?? Encoding.UTF8))
                return sr.ReadToEnd();
        }

        public static string Query(HttpListenerRequest req, string key)
        {
            return req.QueryString[key] ?? "";
        }

        public static string HtmlEscape(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return WebUtility.HtmlEncode(s);
        }

        public static byte[] FromBase64(string s)
        {
            if (string.IsNullOrEmpty(s)) return Array.Empty<byte>();
            try { return Convert.FromBase64String(s); } catch { return Array.Empty<byte>(); }
        }

        public static string ToBase64(byte[] data)
        {
            if (data == null || data.Length == 0) return "";
            return Convert.ToBase64String(data);
        }

        public static string BytesToHex(byte[] data, int max = 64)
        {
            if (data == null || data.Length == 0) return "";
            int n = Math.Min(data.Length, max);
            var sb = new StringBuilder(n * 3);
            for (int i = 0; i < n; i++)
            {
                if (i > 0) sb.Append(' ');
                sb.Append(data[i].ToString("X2"));
            }
            if (data.Length > max) sb.Append(" ...");
            return sb.ToString();
        }
    }
}
