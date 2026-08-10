using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Shuangji.Common;

namespace Shuangji.Common
{
    public sealed class AccountStore
    {
        private readonly object _lock = new object();
        private List<AccountDto> _list = new List<AccountDto>();

        public AccountStore()
        {
            Load();
            if (_list.Count == 0)
            {
                // 默认演示账号
                _list.Add(new AccountDto
                {
                    UserName = "demo",
                    Password = "123456",
                    Enabled = true,
                    Remark = "默认演示账号",
                    MaxConnections = 10
                });
                Save();
            }
        }

        public List<AccountDto> GetAll()
        {
            lock (_lock) return _list.Select(Clone).ToList();
        }

        public AccountDto Find(string user)
        {
            lock (_lock)
                return _list.FirstOrDefault(a =>
                    string.Equals(a.UserName, user, StringComparison.OrdinalIgnoreCase));
        }

        public bool Auth(string user, string pass, out string message)
        {
            message = "";
            var a = Find(user);
            if (a == null) { message = "账号不存在"; return false; }
            if (!a.Enabled) { message = "账号已禁用"; return false; }
            if (a.ExpireAt.HasValue && a.ExpireAt.Value < DateTime.Now) { message = "账号已过期"; return false; }
            if (!string.Equals(a.Password, pass ?? "", StringComparison.Ordinal)) { message = "密码错误"; return false; }
            message = "OK";
            return true;
        }

        public bool Upsert(AccountDto dto, out string message)
        {
            message = "";
            if (dto == null || string.IsNullOrWhiteSpace(dto.UserName))
            {
                message = "用户名不能为空";
                return false;
            }
            lock (_lock)
            {
                var old = _list.FirstOrDefault(a =>
                    string.Equals(a.UserName, dto.UserName, StringComparison.OrdinalIgnoreCase));
                if (old == null)
                {
                    dto.CreatedAt = DateTime.Now;
                    _list.Add(Clone(dto));
                }
                else
                {
                    old.Password = dto.Password ?? old.Password;
                    old.Enabled = dto.Enabled;
                    old.Remark = dto.Remark;
                    old.ExpireAt = dto.ExpireAt;
                    old.MaxConnections = dto.MaxConnections < 0 ? 0 : dto.MaxConnections;
                }
                Save();
            }
            message = "OK";
            return true;
        }

        public bool Delete(string user)
        {
            lock (_lock)
            {
                int n = _list.RemoveAll(a =>
                    string.Equals(a.UserName, user, StringComparison.OrdinalIgnoreCase));
                if (n > 0) Save();
                return n > 0;
            }
        }

        private void Load()
        {
            try
            {
                if (!File.Exists(AppPaths.AccountsFile)) return;
                var json = File.ReadAllText(AppPaths.AccountsFile, Encoding.UTF8);
                var list = SimpleJson.Deserialize<List<AccountDto>>(json);
                if (list != null) _list = list;
            }
            catch { }
        }

        private void Save()
        {
            try
            {
                File.WriteAllText(AppPaths.AccountsFile, SimpleJson.Serialize(_list), Encoding.UTF8);
            }
            catch { }
        }

        private static AccountDto Clone(AccountDto a)
        {
            return new AccountDto
            {
                UserName = a.UserName,
                Password = a.Password,
                Enabled = a.Enabled,
                Remark = a.Remark,
                CreatedAt = a.CreatedAt,
                ExpireAt = a.ExpireAt,
                MaxConnections = a.MaxConnections
            };
        }

        public static string MakeToken(string user)
        {
            string raw = user + "|" + DateTime.UtcNow.Ticks + "|" + Guid.NewGuid().ToString("N");
            using (var sha = SHA256.Create())
            {
                var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(raw));
                return Convert.ToBase64String(hash);
            }
        }
    }
}
