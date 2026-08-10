using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

namespace Shuangji.Common
{
    /// <summary>简易 JSON（System.Web.Extensions）。</summary>
    public static class SimpleJson
    {
        private static readonly JavaScriptSerializer Ser = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

        public static string Serialize(object obj) => Ser.Serialize(obj);
        public static T Deserialize<T>(string json)
        {
            if (string.IsNullOrWhiteSpace(json)) return default(T);
            return Ser.Deserialize<T>(json);
        }

        public static Dictionary<string, object> DeserializeObject(string json)
        {
            if (string.IsNullOrWhiteSpace(json)) return new Dictionary<string, object>();
            return Ser.Deserialize<Dictionary<string, object>>(json) ?? new Dictionary<string, object>();
        }

        public static string GetString(Dictionary<string, object> d, string key, string def = "")
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return def;
            return Convert.ToString(d[key]);
        }

        public static int GetInt(Dictionary<string, object> d, string key, int def = 0)
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return def;
            try { return Convert.ToInt32(d[key]); } catch { return def; }
        }

        public static bool GetBool(Dictionary<string, object> d, string key, bool def = false)
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return def;
            try { return Convert.ToBoolean(d[key]); } catch { return def; }
        }
    }

    public static class AppPaths
    {
        public static string Root
        {
            get
            {
                string dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    "Shuangji");
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                return dir;
            }
        }

        public static string AccountsFile => Path.Combine(Root, "accounts.json");
        public static string PoolsDir
        {
            get
            {
                string d = Path.Combine(Root, "pools");
                if (!Directory.Exists(d)) Directory.CreateDirectory(d);
                return d;
            }
        }

        public static string CertDir
        {
            get
            {
                string d = Path.Combine(Root, "certs");
                if (!Directory.Exists(d)) Directory.CreateDirectory(d);
                return d;
            }
        }
    }
}
