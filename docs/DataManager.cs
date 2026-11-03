using Com.Caimomo.Common.Comparison;
using Newtonsoft.Json.Linq;
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Data;
using System.Threading.Tasks;

#if WINDOWS
using System.Data.SQLite;
using System.Data.SqlClient;
#elif ANDROID
using Microsoft.Data.Sqlite;
using Microsoft.Data.SqlClient;
#endif
using System.IO;

namespace Com.Caimomo.Common
{
    /// <summary>
    /// 数据访问管理器，封装连接池、SQL 兼容转换与执行入口。
    /// </summary>
    public partial class DataManager
    {
        private static readonly Object lockDataObj = new Object();
        /// <summary>
        /// 处理 DataManager 逻辑。
        /// </summary>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        public static DataManager Instance = new DataManager();
        readonly ConcurrentQueue<IDbConnection> DbConnections = new ConcurrentQueue<IDbConnection>();
        //public static string configName = "";
        /// <summary>
/// DataBaseError 字段。
        /// </summary>
        public static event Action DataBaseError;
        private static readonly Object lockErrorObj = new Object();
        private static DateTime alertTime = DateTime.Parse(Settings.GetLocalSetting("AlertTime", DateTime.Now.AddDays(-1).ToString("yyyy-MM-dd")));

        /// <summary>
        /// 触发数据库异常事件通知。
        /// </summary>
        public static void RaiseDataBaseError()
        {
            DataBaseError?.Invoke();
        }

        private DataManager()
        {
            CreateUniqueForOrderZhuoTai();
        }

        /// <summary>
        /// 当前是否使用 SQL Server 数据库。
        /// </summary>
        public static bool UsingSqlServer {
            get {
                return (Settings.GetLocalSetting<int>("deviceactor") == 1);
            }
        }

        /// <summary>
        /// 获取本地数据标识，不存在时自动创建并持久化。
        /// </summary>
        public static string DataMark
        {
            get
            {
                var dataMark = Settings.GetLocalParamValue("DataMark", "");
                if (string.IsNullOrWhiteSpace(dataMark))
                {
                    dataMark = CommonTool.GetGuid();
                    Settings.SetLocalParam("DataMark", dataMark);
                }

                return dataMark;
            }
        }

        /// <summary>
        /// 按当前数据库类型转换 SQL 兼容语法。
        /// </summary>
        /// <param name="strSql">待转换 SQL。</param>
        public void ChangeSql(ref string strSql)
        {
            ChangeSql(UsingSqlServer,ref strSql);
        }

        /// <summary>
        /// 按指定数据库类型转换 SQL 兼容语法。
        /// </summary>
        /// <param name="usingSqlServer">是否按 SQL Server 规则转换。</param>
        /// <param name="strSql">待转换 SQL。</param>
        private void ChangeSql(bool usingSqlServer,ref string strSql)
        {
            if (usingSqlServer)
            {
                if (strSql.IndexOf("IFNULL") > -1)
                    strSql = strSql.Replace("IFNULL", "ISNULL");

                if (strSql.IndexOf("ifnull") > -1)
                    strSql = strSql.Replace("ifnull", "ISNULL");

                if (strSql.IndexOf("Count()") > -1 || strSql.IndexOf("count()") > -1)
                {
                    strSql = strSql.Replace("Count()", "Count(*)");
                    strSql = strSql.Replace("count()", "Count(*)");
                }

                if (strSql.IndexOf("substr") > -1 || strSql.IndexOf("SUBSTR") > -1)
                {
                    strSql = strSql.Replace("substr", "SUBSTRING");
                    strSql = strSql.Replace("SUBSTR", "SUBSTRING");
                }

                if (strSql.IndexOf("length(") > -1 || strSql.IndexOf("LENGTH(") > -1)
                {
                    strSql = strSql.Replace("length(", "LEN(");
                    strSql = strSql.Replace("LENGTH(", "LEN(");
                }
            }
            else
            {
                if (strSql.IndexOf("with(nolock)") > -1)
                {
                    strSql = strSql.Replace("with(nolock)", " ");
                }
                if (strSql.IndexOf("WITH(NOLOCK)") > -1)
                {
                    strSql = strSql.Replace("WITH(NOLOCK)", " ");
                }

                var topMatch = System.Text.RegularExpressions.Regex.Match(strSql,
                    @"\bSELECT\s+(DISTINCT\s+)?TOP\s+(\d+)",
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                if (topMatch.Success)
                {
                    string topNum = topMatch.Groups[2].Value;
                    strSql = System.Text.RegularExpressions.Regex.Replace(strSql,
                        @"\bSELECT\s+(DISTINCT\s+)?TOP\s+\d+\s*",
                        "SELECT $1",
                        System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                    strSql = strSql.TrimEnd() + " LIMIT " + topNum;
                }
            }
        }

        /// <summary>
        /// 获取可用数据库连接（优先复用连接队列）。
        /// </summary>
        /// <returns>数据库连接对象。</returns>
        public IDbConnection GetConnection()
        {
            if (!DbConnections.IsEmpty)
            {
                IDbConnection conn = null;
                bool dequeue = false;
                lock (DbConnections)
                {
                    dequeue = DbConnections.TryDequeue(out conn);
                }
                if (dequeue)
                {
                    bool matchDb = ((UsingSqlServer && (conn is SqlConnection)) || ((!UsingSqlServer) && (!(conn is SqlConnection))));
                    if (matchDb)
                    {
                        if (!object.Equals(conn, null) && (conn.State == ConnectionState.Open))
                            return conn;
                        else
                            return GetConnection();
                    }
                    else
                    {
                        CloseConnection(conn);
                        return GetConnection();
                    }
                }
                else
                {
                    return GetConnection();
                }
            }
            else
            {
                return _GetConn();
            }
        }

        private IDbConnection _GetConn()
        {
            //Log.WriteLog("新开连接");
            if (!UsingSqlServer)
                return SqlLiteHelper.GetConnection();
            else
                return MSSqlHelper.GetConnection();
        }

        /// <summary>
        /// 清理并关闭连接队列中的所有连接。
        /// </summary>
        public void ClearConnections()
        {
            while (DbConnections.Count > 0)
            {
                lock (DbConnections)
                {
                    IDbConnection conn;
                    if (DbConnections.TryDequeue(out conn))
                    {
                        if (conn == null)
                            continue;

#if WINDOWS
                        if (conn is SQLiteConnection)
                        {
                            var sqliteConn = conn as SQLiteConnection;
                            if (sqliteConn != null)
                            {
                                // 清除连接池中的连接
                                SQLiteConnection.ClearPool(sqliteConn);
                            }

                        }
#elif ANDROID
                        if (conn is SqliteConnection)
                        {
                            var sqliteConn = conn as SqliteConnection;
                            if (sqliteConn != null)
                            {
                                // 清除连接池中的连接
                                SqliteConnection.ClearPool(sqliteConn);
                            }

                        }
#endif                        

                        conn.Close();
                        //conn.Dispose();
                    }
                }
            }
        }
        
        /// <summary>
        /// 根据当前数据库类型创建数据适配器。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <returns>数据适配器。</returns>
        public IDataAdapter CreateDataAdapter(IDbCommand cmd)
        {
            if (!UsingSqlServer)
                return SqlLiteHelper.CreateDataAdapter(cmd);
            else
                return MSSqlHelper.CreateDataAdapter(cmd);
        }

        /// <summary>
        /// 按指定数据库类型创建数据适配器。
        /// </summary>
        /// <param name="isUsingSqlServer">是否使用 SQL Server 适配器。</param>
        /// <param name="cmd">数据库命令对象。</param>
        /// <returns>数据适配器。</returns>
        public IDataAdapter CreateDataAdapter(bool isUsingSqlServer,IDbCommand cmd)
        {
            if (!isUsingSqlServer)
                return SqlLiteHelper.CreateDataAdapter(cmd);
            else
                return MSSqlHelper.CreateDataAdapter(cmd);
        }

        /// <summary>
        /// 将 DataTable 转为 JSON 字符串。
        /// </summary>
        /// <param name="tb">数据表对象。</param>
        /// <returns>JSON 字符串。</returns>
        public string DateTableToJson(DataTable tb)
        {
            return SqlLiteHelper.DateTableToJson(tb);
        }

        private void JudgeExecuteTime(string methodName, DateTime beginTime, dynamic strSqls)
        {
            if (DateTime.Now.AddMilliseconds(-500).CompareTo(beginTime) > 0)
            {
                string result = "";

                int index = 1;
                foreach (string strSql in strSqls)
                {
                    if (result.Length > 500)
                        break;

                    result += "\r\n" + strSql;
                    index++;
                }

                Log.WriteLog("连接数：" + (DbConnections.Count + 1));
                if (result.Length <= 500)
                    Log.WriteLog(methodName + ":用时" + (DateTime.Now - beginTime).TotalMilliseconds + "毫秒" + result);
                else
                    Log.WriteLog(methodName + ":用时" + (DateTime.Now - beginTime).TotalMilliseconds + "毫秒");
            }
        }

        private void JudgelockTime(string methodName, DateTime beginTime)
        {
            if (DateTime.Now.AddMilliseconds(-500).CompareTo(beginTime) > 0)
            {
                Log.WriteLog(methodName + ":锁定用时" + (DateTime.Now - beginTime).TotalMilliseconds + "毫秒");
            }
        }

        #region ExecuteNonQuery
        /// <summary>
        /// 执行非查询 SQL（自动管理连接与锁）。
        /// </summary>
        /// <param name="strSql">待执行 SQL。</param>
        /// <returns>执行是否成功。</returns>
        public bool ExecuteNonQuery(string strSql)
        {
            DateTime dt = DateTime.Now;
            lock (GetLockedDataObject())
            {
                JudgelockTime("ExecuteNonQuery", dt);
                IDbConnection conn = null;
                IDbCommand cmd = null;
                try
                {
                    conn = GetConnection();
                    cmd = conn.CreateCommand();
                    return ExecuteNonQuery(cmd, strSql);
                }
                catch (Exception e)
                {
                    Log.WriteLog("execute(string strSql):strSql:" + strSql + "\r\n" + e.ToString());
                    HandleError(e);
                    return false;
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }
        }

        /// <summary>
        /// 在指定命令上下文执行非查询 SQL。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="strSql">待执行 SQL。</param>
        /// <param name="commandTimeout">命令超时（秒）。默认 30 秒；升级/修复数据库时可能执行大表 DDL（如给历史表加非空默认列，需整表重写），耗时远超 30 秒，此时由调用方传入更大的值，0 表示不限制。</param>
        /// <returns>执行是否成功。</returns>
        public bool ExecuteNonQuery(IDbCommand cmd, string strSql, int commandTimeout = 30)
        {
            try
            {
                ChangeSql(ref strSql);
                cmd.CommandText = strSql;
                cmd.CommandTimeout = commandTimeout;
                DateTime dt = DateTime.Now;
                cmd.ExecuteNonQuery();
                JudgeExecuteTime("ExecuteNonQuery", dt, new string[] { strSql });
                return true;
            }
            catch (SqlException e)
            {
                if (e.Number == 1205 && e.Class == 13)//事务死锁
                    throw e;
                Log.WriteLog("DataManager execute(IDbCommand cmd, string strSql):strSql:" + strSql + "\r\n" + e.ToString());
                return false;
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager execute(IDbCommand cmd, string strSql):strSql:" + strSql + "\r\n" + e.ToString());
                HandleError(e);
                return false;
            }
        }

        /// <summary>
        /// 处理 ExecuteNonQueryWithInfluenceNumber 逻辑。
        /// </summary>
        /// <param name="strSql">SQL语句。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteNonQueryWithInfluenceNumber(...);
        /// </code>
        /// </example>
        public int ExecuteNonQueryWithInfluenceNumber(string strSql)
        {
            lock (GetLockedDataObject())
            {
                IDbConnection conn = null;
                IDbCommand cmd = null;
                try
                {
                    conn = GetConnection();
                    cmd = conn.CreateCommand();
                    return ExecuteNonQueryWithInfluenceNumber(cmd, strSql);
                }
                catch (Exception e)
                {
                    Log.WriteLog("JavaScriptInterop execute(string strSql):strSql:" + strSql + "\r\n" + e.ToString());
                    HandleError(e);
                    return -1;
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }
        }

        /// <summary>
        /// 处理 ExecuteNonQueryWithInfluenceNumber 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="strSql">SQL语句。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteNonQueryWithInfluenceNumber(...);
        /// </code>
        /// </example>
        public int ExecuteNonQueryWithInfluenceNumber(IDbCommand cmd, string strSql)
        {
            int result = 0;
            try
            {
                ChangeSql(ref strSql);
                cmd.CommandText = strSql;
                DateTime dt = DateTime.Now;
                result = cmd.ExecuteNonQuery();
                JudgeExecuteTime("ExecuteNonQuery", dt, new string[] { strSql });
                return result;
            }
            catch (SqlException e)
            {
                if (e.Number == 1205 && e.Class == 13)//事务死锁
                    throw e;
                Log.WriteLog("DataManager execute(IDbCommand cmd, string strSql):strSql:" + strSql + "\r\n" + e.ToString());
                return -1;
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager execute(IDbCommand cmd, string strSql):strSql:" + strSql + "\r\n" + e.ToString());
                HandleError(e);
                return -1;
            }
        }

        /// <summary>
        /// 处理 ExecuteNonQuery 逻辑。
        /// </summary>
        /// <param name="strSql">SQL语句。</param>
        /// <param name="args">SQL参数对象。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteNonQuery(...);
        /// </code>
        /// </example>
        public bool ExecuteNonQuery(string strSql, dynamic args)
        {
            DateTime dt = DateTime.Now;
            lock (GetLockedDataObject())
            {
                JudgelockTime("ExecuteNonQuery", dt);
                IDbConnection conn = null;
                IDbCommand cmd = null;
                try
                {
                    ChangeSql(ref strSql);
                    
                    conn = GetConnection();
                    cmd = conn.CreateCommand();

                    if (!object.Equals(args, null) && !object.Equals(DBNull.Value, args))
                    {
                        string[] sqls = strSql.Split('?');
                        if (sqls.Length != (args.Length + 1))
                            return false;

                        for (int i = 0; i < args.Length; i++)
                        {
                            sqls[i] = sqls[i] + ("@P" + i);

                            IDbDataParameter para = cmd.CreateParameter();
                            para.ParameterName = "@P" + i;
                            para.Value = args[i];
                            cmd.Parameters.Add(para);
                        }

                        cmd.CommandText = string.Join(" ", sqls);
                    }
                    else
                        cmd.CommandText = strSql;

                    dt = DateTime.Now;
                    cmd.ExecuteNonQuery();
                    JudgeExecuteTime("ExecuteNonQuery", dt, new string[] { strSql });
                    return true;
                }
                catch (Exception e)
                {
                    Log.WriteLog("DataManager ExecuteNonQuery(string strSql, dynamic args):" + e.ToString());
                    HandleError(e);
                    return false;
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }
        }

        /// <summary>
        /// 处理 ExecuteBatch 逻辑。
        /// </summary>
        /// <param name="strSqls">strSqls 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteBatch(...);
        /// </code>
        /// </example>
        public bool ExecuteBatch(dynamic strSqls)
        {
            DateTime dt = DateTime.Now;
            lock (GetLockedTransObject())
            {
                JudgelockTime("executeBatch", dt);
                dt = DateTime.Now;
                IDbConnection conn = null;
                IDbCommand cmd = null;
                IDbTransaction trans = null;
                try
                {
                    conn = GetConnection();
                    trans = conn.BeginTransaction();
                    cmd = conn.CreateCommand();
                    cmd.Transaction = trans;
                    bool result = ExecuteBatch(cmd, strSqls);
                    if (result)
                        trans.Commit();
                    else
                        trans.Rollback();
                    JudgeExecuteTime("executeBatch", dt, strSqls);
                    return result;
                }
                catch (Exception e)
                {
                    if(! object.Equals(null, trans))
                        trans.Rollback();
                    Log.WriteLog("DataManager executeBatch(dynamic strSqls):" + e.ToString());
                    HandleError(e);
                    return false;
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }
        }

        /// <summary>
        /// 处理 ExecuteBatch 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="strSqls">strSqls 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteBatch(...);
        /// </code>
        /// </example>
        public bool ExecuteBatch(IDbCommand cmd, dynamic strSqls)
        {
            string curSql = "";
            try
            {
                cmd.Parameters.Clear();
                foreach (string strSql in strSqls)
                {
                    curSql = strSql;
                    ChangeSql(ref curSql);
                    cmd.CommandText = curSql;

                    cmd.ExecuteNonQuery();
                }
                return true;
            }
            catch (SqlException e)
            {
                if (e.Number == 1205 && e.Class == 13)//事务死锁
                    throw e;
                Log.WriteLog("DataManager executeBatch(IDbCommand cmd, dynamic strSqls):" + e.ToString() + "\r\n" + curSql);
                return false;
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager executeBatch(IDbCommand cmd, dynamic strSqls):" + e.ToString() + "\r\n" + curSql);
                HandleError(e);
                return false;
            }
        }

        /// <summary>
        /// 处理 ExecuteBatchWithInfluenceNumber 逻辑。
        /// </summary>
        /// <param name="strSqls">strSqls 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteBatchWithInfluenceNumber(...);
        /// </code>
        /// </example>
        public int ExecuteBatchWithInfluenceNumber(dynamic strSqls)
        {
            DateTime dt = DateTime.Now;
            int result = 0;
            lock (GetLockedTransObject())
            {
                JudgelockTime("executeBatch", dt);
                dt = DateTime.Now;
                IDbConnection conn = null;
                IDbCommand cmd = null;
                IDbTransaction trans = null;
                try
                {
                    conn = GetConnection();
                    trans = conn.BeginTransaction();
                    cmd = conn.CreateCommand();
                    cmd.Transaction = trans;
                    result = ExecuteBatchWithInfluenceNumber(cmd, strSqls);
                    if (result > 0)
                        trans.Commit();
                    else
                        trans.Rollback();
                    JudgeExecuteTime("executeBatch", dt, strSqls);
                    return result;
                }
                catch (Exception e)
                {
                    trans.Rollback();
                    Log.WriteLog("DataManager executeBatch(dynamic strSqls):" + e.ToString());
                    HandleError(e);
                    return 0;
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }
        }

        /// <summary>
        /// 处理 ExecuteBatchWithInfluenceNumber 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="strSqls">strSqls 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteBatchWithInfluenceNumber(...);
        /// </code>
        /// </example>
        public int ExecuteBatchWithInfluenceNumber(IDbCommand cmd, dynamic strSqls)
        {
            string curSql = "";
            try
            {
                int result = 0;
                cmd.Parameters.Clear();
                foreach (string strSql in strSqls)
                {
                    curSql = strSql;
                    ChangeSql(ref curSql);
                    cmd.CommandText = curSql;

                    result += cmd.ExecuteNonQuery();
                }
                return result;
            }
            catch (SqlException e)
            {
                if (e.Number == 1205 && e.Class == 13)//事务死锁
                    throw e;
                Log.WriteLog("DataManager executeBatch(IDbCommand cmd, dynamic strSqls):" + e.ToString() + "\r\n" + curSql);
                return 0;
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager executeBatch(IDbCommand cmd, dynamic strSqls):" + e.ToString() + "\r\n" + curSql);
                HandleError(e);
                return 0;
            }
        }

        #endregion


        #region executeQuery
        /// <summary>
        /// 处理 ExecuteQuery 逻辑。
        /// </summary>
        /// <param name="strSql">SQL语句。</param>
        /// <param name="args">SQL参数对象。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteQuery(...);
        /// </code>
        /// </example>
        public string ExecuteQuery(string strSql, dynamic args)
        {
            DataTable dt = ExecuteQueryReturnTable(strSql, args);
            if (dt != null)
                return DateTableToJson(dt);
            else
                return "";
        }

        /// <summary>
/// 处理 ExecuteQuery 逻辑。
        /// </summary>
        public List<T> ExecuteQuery<T>(string strSql, dynamic args)
        {
            DataTable dt = ExecuteQueryReturnTable(strSql, args);
            return SqlLiteHelper.DateTableToEntityList<T>(dt);
        }

        /// <summary>
        /// 处理 ExecuteQuery 逻辑。
        /// </summary>
        /// <param name="strSql">SQL语句。</param>
        /// <param name="args">SQL参数对象。</param>
        /// <param name="entityType">entityType 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteQuery(...);
        /// </code>
        /// </example>
        public IList ExecuteQuery(string strSql, dynamic args,Type entityType)
        {
            DataTable dt = ExecuteQueryReturnTable(strSql, args);
            return SqlLiteHelper.DateTableToEntityList(dt,entityType);
        }

        /// <summary>
        /// 处理 ExecuteQueryReturnTable 逻辑。
        /// </summary>
        /// <param name="strSql">SQL语句。</param>
        /// <param name="args">SQL参数对象。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteQueryReturnTable(...);
        /// </code>
        /// </example>
        public DataTable ExecuteQueryReturnTable(string strSql, dynamic args)
        {
            DateTime lockTime = DateTime.Now;
            lock (GetLockedDataObject())
            {
                JudgelockTime("executeQueryReturnTable", lockTime);
                IDbConnection conn = null;
                IDbCommand cmd = null;
                try
                {
                    conn = GetConnection();
                    cmd = conn.CreateCommand();

                    return ExecuteQuery(cmd, strSql, args);
                }
                catch (Exception e)
                {
                    Log.WriteLog("DataManager executeQueryReturnTable(string strSql, dynamic args):strSql:" + strSql + "\r\n" + e.ToString());
                    HandleError(e);
                    return null;
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }
        }

        /// <summary>
        /// 处理 ExecuteQuery 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="strSql">SQL语句。</param>
        /// <param name="args">SQL参数对象。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteQuery(...);
        /// </code>
        /// </example>
        public DataTable ExecuteQuery(IDbCommand cmd, string strSql, dynamic args)
        {
            IDataAdapter adapter = null;
            try
            {
                ChangeSql(ref strSql);
                cmd.Parameters.Clear();
                if (!object.Equals(args, null) && !object.Equals(DBNull.Value, args))
                {
                    string[] sqls = strSql.Split('?');
                    if (sqls.Length != (args.Length + 1))
                        return null;

                    for (int i = 0; i < args.Length; i++)
                    {
                        sqls[i] = sqls[i] + ("@P" + i);
                        IDbDataParameter para = cmd.CreateParameter();
                        para.ParameterName = "@P" + i;
                        para.Value = args[i];
                        cmd.Parameters.Add(para);
                    }

                    cmd.CommandText = string.Join(" ", sqls);
                }
                else
                {
                    cmd.CommandText = strSql;
                }

                DataSet dst = new DataSet();
                DateTime dt = DateTime.Now;
                adapter = CreateDataAdapter(cmd);

                adapter.Fill(dst);                
                JudgeExecuteTime("executeQuery", dt, new string[] { strSql });
                return dst.Tables[0];
            }
            catch (SqlException e)
            {
                if (e.Number == 1205 && e.Class == 13)//事务死锁
                    throw e;
                Log.WriteLog("DataManager executeQuery(IDbCommand cmd, string strSql, dynamic args):" + e.ToString() + "\r\n" + strSql);
                HandleError(e);
                return null;
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager executeQuery(IDbCommand cmd, string strSql, dynamic args):" + e.ToString() + "\r\n" + strSql);
                return null;
            }
            finally
            {
                DisposeAdapter(adapter);
            }
        }

        #endregion

        /// <summary>
        /// 处理 ExecuteScalar 逻辑。
        /// </summary>
        /// <param name="strSql">SQL语句。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteScalar(...);
        /// </code>
        /// </example>
        public object ExecuteScalar(string strSql)
        {
            object result = null;
            DateTime lockTime = DateTime.Now;
            lock (GetLockedDataObject())
            {
                JudgelockTime("executeScalar", lockTime);
                IDbConnection conn = null;
                IDbCommand cmd = null;
                try
                {
                    ChangeSql(ref strSql);
                    conn = GetConnection();
                    cmd = conn.CreateCommand();
                    cmd.CommandText = strSql;
                    DateTime dt = DateTime.Now;
                    result = cmd.ExecuteScalar();
                    JudgeExecuteTime("executeScalar", dt, new string[] { strSql });
                }
                catch (Exception e)
                {
                    Log.WriteLog("DataManager executeScalar(string strSql):strSql:" + strSql + "\r\n" + e.ToString());
                    HandleError(e);
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }

            return result;
        }

        /// <summary>
        /// 处理 ExecuteScalar 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="strSql">SQL语句。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteScalar(...);
        /// </code>
        /// </example>
        public object ExecuteScalar(IDbCommand cmd, string strSql)
        {
            object result = null;
            DateTime lockTime = DateTime.Now;

            JudgelockTime("ExecuteScalar", lockTime);
            try
            {
                ChangeSql(ref strSql);
                cmd.CommandText = strSql;
                DateTime dt = DateTime.Now;
                result = cmd.ExecuteScalar();
                JudgeExecuteTime("ExecuteScalar", dt, new string[] { strSql });
            }
            catch (SqlException e)
            {
                if (e.Number == 1205 && e.Class == 13)//事务死锁
                    throw e;
                Log.WriteLog("DataManager ExecuteScalar(IDbCommand cmd,string strSql):strSql:" + strSql + "\r\n" + e.ToString());
                HandleError(e);
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager ExecuteScalar(IDbCommand cmd,string strSql):strSql:" + strSql + "\r\n" + e.ToString());
            }

            return result;
        }

        /// <summary>
        /// 处理 ExecuteScalar 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="strSql">SQL语句。</param>
        /// <param name="args">SQL参数对象。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteScalar(...);
        /// </code>
        /// </example>
        public object ExecuteScalar(IDbCommand cmd, string strSql, dynamic args)
        {
            object result = null;
            IDataAdapter adapter = null;
            try
            {
                ChangeSql(ref strSql);
                cmd.Parameters.Clear();
                if (!object.Equals(args, null) && !object.Equals(DBNull.Value, args))
                {
                    string[] sqls = strSql.Split('?');
                    if (sqls.Length != (args.Length + 1))
                        return null;

                    for (int i = 0; i < args.Length; i++)
                    {
                        sqls[i] = sqls[i] + ("@P" + i);
                        IDbDataParameter para = cmd.CreateParameter();
                        para.ParameterName = "@P" + i;
                        para.Value = args[i];
                        cmd.Parameters.Add(para);
                    }

                    cmd.CommandText = string.Join(" ", sqls);
                }
                else
                {
                    cmd.CommandText = strSql;
                }

                DateTime dt = DateTime.Now;
                result = cmd.ExecuteScalar();
                JudgeExecuteTime("ExecuteScalar", dt, new string[] { strSql });
                return result;
            }
            catch (SqlException e)
            {
                if (e.Number == 1205 && e.Class == 13)//事务死锁
                    throw e;
                Log.WriteLog("DataManager ExecuteScalar(IDbCommand cmd,string strSql):strSql:" + strSql + "\r\n" + e.ToString());
                HandleError(e);
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager ExecuteScalar(IDbCommand cmd,string strSql):strSql:" + strSql + "\r\n" + e.ToString());
            }

            return result;
        }
        /// <summary>
        /// 处理 ExecuteScalar 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="sql">SQL语句。</param>
        /// <param name="paramName">paramName 参数。</param>
        /// <param name="paramValue">paramValue 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.ExecuteScalar(...);
        /// </code>
        /// </example>
        public object ExecuteScalar(IDbCommand cmd, string sql, params (string paramName, object paramValue)[] parameters)
        {
            // 基础校验
            if (cmd == null)
                throw new ArgumentNullException(nameof(cmd), "数据库命令对象不能为空");
            if (string.IsNullOrWhiteSpace(sql))
                throw new ArgumentNullException(nameof(sql), "SQL语句不能为空");

            try
            {
                // 1. 重置命令对象
                cmd.CommandText = sql;
                cmd.CommandType = CommandType.Text;
                cmd.Parameters.Clear(); // 清空旧参数，避免冲突

                // 2. 绑定命名参数（核心逻辑）
                if (parameters != null && parameters.Length > 0)
                {
                    foreach (var (paramName, paramValue) in parameters)
                    {
                        // 确保参数名以@开头（兼容传入不带@的情况）
                        string actualParamName = paramName.StartsWith("@") ? paramName : $"@{paramName}";

                        // 创建参数并设置值
                        IDataParameter param = cmd.CreateParameter();
                        param.ParameterName = actualParamName;
                        // 空值转DBNull，避免数据库报错
                        param.Value = paramValue ?? DBNull.Value;

                        // 可选：自动适配常见类型（提升兼容性）
                        if (paramValue is DateTime) param.DbType = DbType.DateTime;
                        else if (paramValue is Guid) param.DbType = DbType.Guid;
                        else if (paramValue is string) param.DbType = DbType.String;
                        else if (paramValue is int) param.DbType = DbType.Int32;

                        cmd.Parameters.Add(param);
                    }
                }

                // 3. 执行SQL并返回结果（连接/事务由外部管理）
                return cmd.ExecuteScalar();
            }
            catch (Exception ex)
            {
                // 包装异常信息，便于排查
                throw new Exception($"ExecuteScalar执行失败：SQL={sql}，错误：{ex.Message}", ex);
            }
            finally
            {
                // 执行后清空参数，避免复用命令对象时参数残留
                cmd.Parameters.Clear();
            }
        }


        #region insert
        /// <summary>
        /// 处理 InsertTable 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="tableName">表名。</param>
        /// <param name="JsonData">JsonData 参数。</param>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// YourObject.InsertTable(...);
        /// </code>
        /// </example>
        public void InsertTable(IDbCommand cmd, string tableName, dynamic JsonData)
        {
            for (int i = 0; i < JsonData.Length; i++)
            {
                InsertSingleRecord(cmd, tableName, JsonData[i]);
            }
        }

        /// <summary>
        /// 处理 InsertSingleRecord 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="tableName">表名。</param>
        /// <param name="JsonData">JsonData 参数。</param>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// YourObject.InsertSingleRecord(...);
        /// </code>
        /// </example>
        public void InsertSingleRecord(IDbCommand cmd, string tableName, string JsonData)
        {
            cmd.Parameters.Clear();

            Dictionary<string, object> dicJson = JsonTool.ToDictionary(JsonData);
            string insertSql = "INSERT INTO " + tableName + "(";
            string valuesSql = "VALUES(";

            foreach (string key in dicJson.Keys)
            {
                if (object.Equals(null, dicJson[key]))
                    continue;

                insertSql = insertSql + key + ",";
                valuesSql = valuesSql + "@" + key + ",";

                IDbDataParameter para = cmd.CreateParameter();
                para.ParameterName = "@" + key;
                if (dicJson[key] is System.DateTime)
                    para.Value = Convert.ToDateTime(dicJson[key]).ToString("yyyy-MM-ddTHH:mm:ss");
                else
                    para.Value = dicJson[key];
                cmd.Parameters.Add(para);
            }

            insertSql = insertSql.Substring(0, insertSql.Length - 1);
            valuesSql = valuesSql.Substring(0, valuesSql.Length - 1);
            cmd.CommandText = insertSql + ") " + valuesSql + ")";

            try
            {
                var result = cmd.ExecuteNonQuery();
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager insertSingleRecord():\r\nsql:" + (insertSql + ") " + valuesSql + ")") + "\r\n" + e.ToString());
                HandleError(e);
                throw e;
            }
        }

        //插入对象
        /// <summary>
        /// 处理 Insert 逻辑。
        /// </summary>
        /// <param name="tableName">表名。</param>
        /// <param name="JsonData">JsonData 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.Insert(...);
        /// </code>
        /// </example>
        public bool Insert(string tableName, dynamic JsonData)
        {
            DateTime lockTime = DateTime.Now;
            lock (GetLockedDataObject())
            {
                JudgelockTime("insert", lockTime);
                DateTime dt = DateTime.Now;
                IDbConnection conn = null;
                IDbCommand cmd = null;
                //IDbTransaction trans = null;
                try
                {
                    conn = GetConnection();
                    //trans = conn.BeginTransaction();
                    cmd = conn.CreateCommand();
                    //cmd.Transaction = trans;

                    InsertTable(cmd, tableName, JsonData);

                    //trans.Commit();

                    JudgeExecuteTime("insert", dt, JsonData);
                    return true;
                }
                catch (Exception e)
                {
                    //if (! object.Equals(trans,null))
                    //    trans.Rollback();
                    Log.WriteLog("DataManager insert(string tableName, dynamic JsonData):tableName:" + tableName + "\r\n" + e.ToString());
                    HandleError(e);
                    return false;
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }
        }

        /// <summary>
        /// 处理 InsertBatch 逻辑。
        /// </summary>
        /// <param name="tableName1">tableName1 参数。</param>
        /// <param name="JsonData1">JsonData1 参数。</param>
        /// <param name="tableName2">tableName2 参数。</param>
        /// <param name="JsonData2">JsonData2 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.InsertBatch(...);
        /// </code>
        /// </example>
        public bool InsertBatch(string tableName1, dynamic JsonData1, string tableName2, dynamic JsonData2)
        {
            return Insert(tableName1, JsonData1, tableName2, JsonData2);
        }

        /// <summary>
        /// 处理 insertEntities 逻辑。
        /// </summary>
        /// <param name="jsonDatas">jsonDatas 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.insertEntities(...);
        /// </code>
        /// </example>
        public bool insertEntities(dynamic jsonDatas)
        {
            if (jsonDatas.Length <= 0)
                return true;

            DateTime lockTime = DateTime.Now;
            lock (GetLockedTransObject())
            {
                JudgelockTime("insert", lockTime);
                DateTime dt = DateTime.Now;
                IDbConnection conn = null;
                IDbTransaction trans = null;
                try
                {
                    conn = GetConnection();
                    trans = conn.BeginTransaction();
                    IDbCommand cmd = conn.CreateCommand();
                    cmd.Transaction = trans;

                    for (int i = 0; i < jsonDatas.Length; i++)
                    {
                        var jsonData = jsonDatas[i] as System.Collections.Generic.Dictionary<string, object>;
                        if (object.Equals(null, jsonData))
                            jsonData = JsonTool.ToDictionary(jsonDatas[i].ToString());

                        var tableName = jsonData["TableName"].ToString();
                        object[] jsonEntities = jsonData["Entities"] as object[];
                        if (object.Equals(null, jsonEntities))
                        {
                            if (jsonData["Entities"] is JArray)
                            {
                                List<string> lstEntities = new List<string>();
                                foreach (var obj in ((JArray)jsonData["Entities"]))
                                {
                                    //Dictionary<string, object> entity = new Dictionary<string, object>();

                                    //JObject objToken = JObject.Parse(obj.ToString());
                                    //foreach (var x in objToken)
                                    //{
                                    //    entity.Add(x.Key, ((Newtonsoft.Json.Linq.JValue)(x.Value)).Value);
                                    //}

                                    lstEntities.Add(obj.ToString());
                                }

                                jsonEntities = lstEntities.ToArray();
                            }
                        }

                        if (object.Equals(null, jsonEntities) || jsonEntities.Length <= 0)
                            throw new Exception("非法数据");

                        InsertTable(cmd, tableName, jsonEntities);
                    }

                    trans.Commit();
                    JudgeExecuteTime("insertEntities", dt, new string[] { });
                    return true;
                }
                catch (Exception e)
                {
                    trans.Rollback();
                    Log.WriteLog("DataManager insertEntities(dynamic JsonData):JsonData:" + jsonDatas + "\r\n" + e.ToString());
                    HandleError(e);
                    return false;
                }
                finally
                {
                    CloseConnection(conn);
                }
            }
        }

        /// <summary>
        /// 处理 Insert 逻辑。
        /// </summary>
        /// <param name="tableName1">tableName1 参数。</param>
        /// <param name="JsonData1">JsonData1 参数。</param>
        /// <param name="tableName2">tableName2 参数。</param>
        /// <param name="JsonData2">JsonData2 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.Insert(...);
        /// </code>
        /// </example>
        public bool Insert(string tableName1, dynamic JsonData1, string tableName2, dynamic JsonData2)
        {
            DateTime lockTime = DateTime.Now;
            lock (GetLockedTransObject())
            {
                JudgelockTime("insert", lockTime);
                DateTime dt = DateTime.Now;
                IDbConnection conn = null;
                IDbTransaction trans = null;
                IDbCommand cmd = null;

                try
                {
                    conn = GetConnection();
                    trans = conn.BeginTransaction();
                    cmd = conn.CreateCommand();
                    cmd.Transaction = trans;

                    if (!Insert(cmd, tableName1, JsonData1, tableName2, JsonData2))
                    {
                        trans.Rollback();
                        return false;
                    }

                    trans.Commit();
                    JudgeExecuteTime("insertSingleRecord", dt, new string[] { });
                    return true;
                }
                catch (Exception e)
                {
                    trans.Rollback();
                    Log.WriteLog("DataManager insert(string tableName1, dynamic JsonData1, string tableName2, dynamic JsonData2):tableName1:" + tableName1 + " JsonData1:" + JsonData1 + " tableName2:" + tableName2 + " JsonData2:" + JsonData2 + "\r\n" + e.ToString());
                    HandleError(e);
                    return false;
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();

                    CloseConnection(conn);
                }
            }
        }

        /// <summary>
        /// 处理 Insert 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="tableName1">tableName1 参数。</param>
        /// <param name="JsonData1">JsonData1 参数。</param>
        /// <param name="tableName2">tableName2 参数。</param>
        /// <param name="JsonData2">JsonData2 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.Insert(...);
        /// </code>
        /// </example>
        public bool Insert(IDbCommand cmd, string tableName1, dynamic JsonData1, string tableName2, dynamic JsonData2)
        {
            try
            {
                InsertTable(cmd, tableName1, JsonData1);
                InsertTable(cmd, tableName2, JsonData2);
                return true;
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager insert(IDbCommand cmd, string tableName1, dynamic JsonData1, string tableName2, dynamic JsonData2):tableName1:" + tableName1 + " tableName2:" + tableName2 + "\r\n" + e.ToString());
                return false;
            }
        }

        #endregion

        /// <summary>
        /// 处理 Update 逻辑。
        /// </summary>
        /// <param name="cmd">数据库命令对象。</param>
        /// <param name="tableName">表名。</param>
        /// <param name="JsonData">JsonData 参数。</param>
        /// <param name="where">where 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.Update(...);
        /// </code>
        /// </example>
        public int Update(IDbCommand cmd, string tableName, string JsonData, string where)
        {
            var updateSql = "";
            try
            {
                Dictionary<string, object> dicJson = JsonTool.Deserialize<Dictionary<string, object>>(JsonData);

                updateSql = "UPDATE " + tableName + " SET ";
                foreach (string key in dicJson.Keys)
                {
                    if (object.Equals(null, dicJson[key]))
                        continue;

                    updateSql = updateSql + key + "=@" + key + ",";

                    IDbDataParameter para = cmd.CreateParameter();
                    para.ParameterName = "@" + key;
                    if (dicJson[key] is System.DateTime)
                        para.Value = Convert.ToDateTime(dicJson[key]).ToString("yyyy-MM-ddTHH:mm:ss");
                    else
                        para.Value = dicJson[key];
                    cmd.Parameters.Add(para);
                }

                updateSql = updateSql.Substring(0, updateSql.Length - 1) + " WHERE " + where;
                cmd.CommandText = updateSql;
                DateTime dt = DateTime.Now;
                int result = cmd.ExecuteNonQuery();
                JudgeExecuteTime("update", dt, new string[] { JsonData });
                return result;
            }
            catch (SqlException e)
            {
                if (e.Number == 1205 && e.Class == 13)//事务死锁
                    throw e;
                Log.WriteLog("DataManager update():tableName:" + tableName + "\r\nsql:" + updateSql + "\r\n" + e.ToString());
                return 0;
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager update():tableName:" + tableName + "\r\nsql:" + updateSql + "\r\n" + e.ToString());
                HandleError(e);
                return 0;
            }
        }

        //更新数据
        /// <summary>
        /// 处理 Update 逻辑。
        /// </summary>
        /// <param name="tableName">表名。</param>
        /// <param name="JsonData">JsonData 参数。</param>
        /// <param name="where">where 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.Update(...);
        /// </code>
        /// </example>
        public int Update(string tableName, string JsonData, string where)
        {
            DateTime lockTime = DateTime.Now;
            lock (GetLockedDataObject())
            {
                JudgelockTime("update", lockTime);
                IDbConnection conn = null;
                IDbCommand cmd = null;
                try
                {
                    conn = GetConnection();
                    cmd = conn.CreateCommand();
                    return Update(cmd, tableName, JsonData, where);
                }
                catch (Exception e)
                {
                    Log.WriteLog("DataManager update():tableName:" + tableName + "\r\ndata:" + JsonData + "\r\n" + e.ToString());
                    HandleError(e);
                    return 0;
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }
        }

        // 删除表数据
        /// <summary>
        /// 处理 Delete 逻辑。
        /// </summary>
        /// <param name="tableName">表名。</param>
        /// <param name="where">where 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.Delete(...);
        /// </code>
        /// </example>
        public int Delete(string tableName, string where)
        {
            DateTime lockTime = DateTime.Now;
            lock (GetLockedDataObject())
            {
                JudgelockTime("update", lockTime);
                IDbConnection conn = null;
                IDbCommand cmd = null;
                try
                {
                    conn = GetConnection();
                    cmd = conn.CreateCommand();
                    cmd.CommandText = "DELETE FROM " + tableName + " WHERE " + where;
                    DateTime dt = DateTime.Now;
                    int result = cmd.ExecuteNonQuery();
                    JudgeExecuteTime("delete", dt, new string[] { tableName + "where" });
                    return result;
                }
                catch (Exception e)
                {
                    Log.WriteLog($"DataManager Delete():tableName:{tableName }  where:{ where}\r\n" + e.ToString());
                    HandleError(e);
                    throw e;
                }
                finally
                {
                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }
        }

        /// <summary>
        /// 获取 Data Set 信息。
        /// </summary>
        /// <param name="strSql">SQL语句。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.GetDataSet(...);
        /// </code>
        /// </example>
        public DataSet GetDataSet(string strSql)
        {
            IDbConnection conn = null;
            IDbCommand cmd = null;
            try
            {
                conn = GetConnection();
                if (object.Equals(null, conn))
                    return null;

                cmd = conn.CreateCommand();
                ChangeSql(ref strSql);
                cmd.CommandText = strSql;

                DataSet dst = new DataSet();
                DateTime dt = DateTime.Now;
                IDataAdapter adapter = CreateDataAdapter(cmd);
                adapter.Fill(dst);
                DisposeAdapter(adapter);
                return dst;
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager GetDataSet():strSql:" + strSql + "\r\n" + e.ToString());
                HandleError(e);
                throw e;
            }
            finally
            {
                if (!object.Equals(null, cmd))
                    cmd.Dispose();
                CloseConnection(conn);
            }
        }

        //获取指定sqlserver服务器上所有数据库
        /// <summary>
        /// 获取 All DB 信息。
        /// </summary>
        /// <param name="strConn">strConn 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.GetAllDB(...);
        /// </code>
        /// </example>
        public static List<string> GetAllDB(string strConn)
        {
            List<string> result = new List<string>();
            IDbConnection conn = null;
            try
            {
                conn = new SqlConnection(strConn);
                if (object.Equals(null, conn))
                    return null;

                conn.Open();

                IDbCommand cmd = conn.CreateCommand();
                //cmd.CommandTimeout = 10;
                cmd.CommandText = "SELECT name FROM MASTER.DBO.SYSDATABASES WHERE dbid > 4 ORDER BY NAME";

                DataSet dst = new DataSet();
                DateTime dt = DateTime.Now;
                IDataAdapter adapter = new SqlDataAdapter(cmd as SqlCommand);
                adapter.Fill(dst);
                foreach (DataRow dr in dst.Tables[0].Rows)
                {
                    result.Add(dr["name"].ToString());
                }
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager GetAllDB():" + e.ToString());
                HandleError(e);
                return result;
            }
            finally
            {
                if (!object.Equals(null, conn))
                    conn.Close();
            }

            return result;
        }

        #region 事务

        /// <summary>
        /// 处理 BeginTrans 逻辑。
        /// </summary>
        /// <param name="conn">conn 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.BeginTrans(...);
        /// </code>
        /// </example>
        public IDbTransaction BeginTrans(IDbConnection conn)
        {
            return conn.BeginTransaction();
        }

        /// <summary>
        /// 处理 CommitTrans 逻辑。
        /// </summary>
        /// <param name="trans">trans 参数。</param>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// YourObject.CommitTrans(...);
        /// </code>
        /// </example>
        public void CommitTrans(IDbTransaction trans)
        {
            if (!object.Equals(null, trans))
                trans.Commit();
        }

        /// <summary>
        /// 处理 RollbackTrans 逻辑。
        /// </summary>
        /// <param name="trans">trans 参数。</param>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// YourObject.RollbackTrans(...);
        /// </code>
        /// </example>
        public void RollbackTrans(IDbTransaction trans)
        {
            if (object.Equals(null, trans))
                return;
            try
            {
                trans.Rollback();
            }
            catch (Exception ex)
            {
                // 触发器已在服务端 ROLLBACK（如 OrderZhuoTai 防重冲突）或连接已断开时，
                // 客户端事务对象已失效，回滚目标实际已达成：此类"事务已终止"异常记录日志后忽略，
                // 避免二次异常覆盖原始错误；其余异常照常抛出，不掩盖真实故障。
                if (IsTransactionAbortedException(ex))
                    Log.WriteLog("RollbackTrans:事务已终止,忽略回滚异常: " + ex.Message);
                else
                    throw;
            }
        }

        /// <summary>
        /// 判断异常是否属于"事务已被终止/已结束"：客户端事务状态失效（InvalidOperationException）
        /// 或服务端已回滚（SqlException 特定错误号）。此时调用方"回滚"目标已达成，可安全忽略。
        /// </summary>
        static bool IsTransactionAbortedException(Exception ex)
        {
            if (ex is InvalidOperationException)
                return true;

            if (ex is SqlException sqlEx)
            {
                switch (sqlEx.Number)
                {
                    // 266: 事务在触发器中中止,批处理已中止; 3609: 事务在触发器中结束
                    // 3902: COMMIT/ROLLBACK 没有对应的 BEGIN TRANSACTION
                    // 3930: 当前事务无法提交,也无法执行写入日志的操作,请回滚该事务
                    // 3961: 快照隔离下事务无法提交; 3980: 事务失败
                    case 266:
                    case 3609:
                    case 3902:
                    case 3930:
                    case 3961:
                    case 3980:
                        return true;
                }
            }
            return false;
        }

        #endregion

        /// <summary>
        /// 获取 Locked Data Object 信息。
        /// </summary>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.GetLockedDataObject(...);
        /// </code>
        /// </example>
        public static Object GetLockedDataObject()
        {
            if (!UsingSqlServer)
                return lockDataObj;
            else
                return new Object();
        }

        /// <summary>
        /// 获取 Locked Trans Object 信息。
        /// </summary>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.GetLockedTransObject(...);
        /// </code>
        /// </example>
        public static Object GetLockedTransObject()
        {
            return lockDataObj;
        }

        /// <summary>
        /// 处理 DisposeAdapter 逻辑。
        /// </summary>
        /// <param name="adapter">adapter 参数。</param>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// YourObject.DisposeAdapter(...);
        /// </code>
        /// </example>
        public void DisposeAdapter(IDataAdapter adapter)
        {
#if ANDROID
            if (object.Equals(adapter, null))
                return;

            if (adapter is SqliteDataAdapter)
                (adapter as SqliteDataAdapter).Dispose();
#endif
        }

        /// <summary>
        /// 关闭 Connection 资源。
        /// </summary>
        /// <param name="conn">conn 参数。</param>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// YourObject.CloseConnection(...);
        /// </code>
        /// </example>
        public void CloseConnection(IDbConnection conn)
        {
            lock (DbConnections)
            {
                if (!object.Equals(conn, null))
                {
                    lock (DbConnections)
                    {
                        if (!object.Equals(conn, null))
                        {
                            var isClose = true;
                            if (DbConnections.Count <= 2)
                            {
                                if (UsingSqlServer)
                                {
                                    if (conn is SqlConnection)
                                    {
#if WINDOWS
                                        string dataSource = ((System.Data.SqlClient.SqlConnection)conn).DataSource;
#elif ANDROID
                                        string dataSource = ((SqlConnection)conn).DataSource;
#endif
                                        if (string.Equals(MSSqlHelper.DataBase, conn.Database, StringComparison.CurrentCultureIgnoreCase) && string.Equals(MSSqlHelper.DataSource, dataSource, StringComparison.CurrentCultureIgnoreCase))
                                        {
                                            isClose = false;
                                            DbConnections.Enqueue(conn);
                                        }
                                    }
                                }
                                else
                                {
#if WINDOWS
                                    if (conn is SQLiteConnection)
                                    {
                                        var sqliteConn = (SQLiteConnection)conn;
                                        string dataSource = new SQLiteConnectionStringBuilder(sqliteConn.ConnectionString).DataSource;
                                        // 与 SQL Server 分支对称：仅当连接仍属于当前库时才入队复用，避免跨库连接污染连接池
                                        if (string.Equals(dataSource, SqlLiteHelper.CurrentDataFile, StringComparison.OrdinalIgnoreCase))
                                        {
                                            isClose = false;
                                            DbConnections.Enqueue(conn);
                                        }
                                    }
#elif ANDROID
                                    if (conn is SqliteConnection)
                                    {
                                        isClose = false;
                                        DbConnections.Enqueue(conn);
                                    }

#endif
                                }
                            }

                            if (isClose)
                                conn.Close();
                        }
                    }
                }
            }
        }

        /// <summary>
        /// 收缩日志
        /// </summary>
        public void ShrinkDbLog()
        {
            if (!DataManager.UsingSqlServer)
                return;

            //var databaseName = GetConnection().Database;
            //var logName = databaseName + "_log";

            //int count = 0;
            //while (count < 3)
            //{
            //    string sql = "BACKUP LOG " + databaseName + " TO DISK= 'NUL:' WITH RETAINDAYS= 1,COMPRESSION\r\ndbcc shrinkfile(N'" + databaseName + "_log',0)";
            //    bool result = ExecuteNonQuery(sql);

            //    if (!result)
            //    {
            //        sql = "BACKUP DATABASE [" + databaseName + "]  TO  DISK = 'NUL:'   WITH INIT,NOUNLOAD,NAME=N'dhchis backup' ,SKIP,STATS=10, FORMAT";
            //        ExecuteNonQuery(sql);
            //    }

            //    count++;
            //}

            LogShrinkOptimizer.OptimizedShrinkDbLog();
        }

        /// <summary>
        /// 比对数据库
        /// </summary>
        /// <returns>返回是否成功。</returns>
        public bool Comparisons(out string errorMsg)
        {
            errorMsg = "";
            string downloadError = "";
            var task = Task.Factory.StartNew(() => UpdateStandardData(out downloadError));
            task.Wait();

            if (!string.IsNullOrWhiteSpace(downloadError))
            {
                errorMsg = downloadError;
                return false;
            }

            DataComparison dataComparison = new DataComparison();
            //先从服务器上下载文件
            //dataComparison.DownLoad("/QiantaiWeb/clientfile/StandardData.xml", Application.StartupPath + @"\patches\StandardData.xml");
            //获取标准数据库路径

            if (!File.Exists(Settings.ApplicationRootPath + "patches" + Path.DirectorySeparatorChar + "StandardData.xml"))
            {
                errorMsg = "未找到标准数据库文件";
                return false;
            }

            string result = dataComparison.DataComparisonByTable();

            if (string.IsNullOrWhiteSpace(result))
                return true;
            else
            {
                errorMsg = result;
                return false;
            }

        }

        /// <summary>
        /// 更新数据库比对文件
        /// </summary>
        /// <param name="errorMsg">下载/复制失败的具体原因</param>
        /// <returns>返回是否成功。</returns>
        protected bool UpdateStandardData(out string errorMsg)
        {
            errorMsg = "";
            bool result = false;
            String tempFile = Path.GetTempPath() + "StandardData.xml";

            string path = Settings.ServerUrl + "/ClientFile/StandardData" + CommonTool.GetLocalVersion() + ".xml";

            if (FileProcessor.DownLoadFile(tempFile, path, null, out errorMsg))
            {
                if (FileProcessor.CopyFile(tempFile, Settings.ApplicationRootPath + "patches" + Path.DirectorySeparatorChar + "StandardData.xml"))
                {
                    result = true;
                }
                else
                {
                    errorMsg = "复制标准库文件到本地失败：" + path;
                }
            }
            else if (string.IsNullOrWhiteSpace(errorMsg))
            {
                errorMsg = "下载标准库文件失败：" + path;
            }

            return result;
        }

        /// <summary>
        /// 处理 TestConnectToDb 逻辑。
        /// </summary>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        public void TestConnectToDb()
        {
            IDbConnection conn = null;
            try
            {
                conn = SqlLiteHelper.GetConnection();
            }
            catch (Exception ex)
            {
                Log.WriteLog("JavaScriptInterop testConnectToDb():\r\n" + ex.ToString());
            }
            finally
            {
                if (!object.Equals(null, conn))
                    conn.Close();
            }
        }

        /// <summary>
        /// 本机设置页面，切换数据库时获取数据
        /// </summary>
        /// <param name="isUsingSqlServer">isUsingSqlServer 参数。</param>
        /// <param name="sql">SQL语句。</param>
        /// <returns>返回是否成功。</returns>
        public string GetDataForLocalSetting(bool isUsingSqlServer, string sql)
        {
            string result = "";

            ChangeSql(isUsingSqlServer,ref sql);

            lock (DataManager.GetLockedDataObject())
            {
                IDbConnection conn = null;
                IDbCommand cmd = null;
                IDataAdapter adapter = null;

                try
                {
                    if (!isUsingSqlServer)
                        conn = SqlLiteHelper.GetConnection();
                    else
                        conn = MSSqlHelper.GetConnection();


                    cmd = conn.CreateCommand();
                    cmd.CommandText = sql;

                    DataSet dst = new DataSet();
                    DateTime dt = DateTime.Now;
                    adapter = CreateDataAdapter(isUsingSqlServer, cmd);
                    adapter.Fill(dst);

                    if (dst.Tables.Count > 0)
                        result = DateTableToJson(dst.Tables[0]);
                }
                catch (Exception e)
                {
                    Log.WriteLog("JavaScriptop getDataForLocalSetting()\t\n" + e.ToString());
                }
                finally
                {
                    DisposeAdapter(adapter);

                    if (!object.Equals(null, cmd))
                        cmd.Dispose();
                    CloseConnection(conn);
                }
            }

            return result;
        }

        /// <summary>
        /// 是否存在指定数据表
        /// </summary>
        /// <param name="tableName">表名。</param>
        /// <returns>返回是否成功。</returns>
        public bool ExistTable(string tableName)
        {
            var sql = "SELECT count(*) C FROM sqlite_master WHERE type='table' AND name='" + tableName + "'";
            if (DataManager.UsingSqlServer)
                sql = "SELECT count(*) FROM dbo.sysobjects WHERE id = OBJECT_ID(N'[" + tableName + "]') AND OBJECTPROPERTY(id, N'IsUserTable') = 1";

            return Convert.ToInt32(DataManager.Instance.ExecuteScalar(sql)) > 0;
        }

        static bool _isHandlingError = false;
        /// <summary>
        /// 处理 HandleError 逻辑。
        /// </summary>
        /// <param name="ex">ex 参数。</param>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// YourObject.HandleError(...);
        /// </code>
        /// </example>
        public static void HandleError(Exception ex)
        {
#if WINDOWS
            var exception = ex as System.Data.SQLite.SQLiteException;
#elif ANDROID
            var exception = ex as Microsoft.Data.Sqlite.SqliteException;
#endif

            if (exception == null)
                return;

            lock (lockErrorObj)
            {
                if (_isHandlingError)
                    return;
                else
                    _isHandlingError = true;
            }

            if (exception.Message.Contains("malformed"))
            {
                if (alertTime != null && alertTime.Date.CompareTo(DateTime.Today) >= 0)
                {
                    RaiseDataBaseError();
                    _isHandlingError = false;
                    return;
                }

                var task = Task.Factory.StartNew(() =>
                {
                    if (SendSms("数据库已损坏，门店号：" + UserManager.CurrentStoreID).CompleteSuccess)
                    {
                        alertTime = DateTime.Now;
                        _isHandlingError = false;
                        Settings.SetLocalSettings("AlertTime", alertTime.ToString("yyyy-MM-dd"));
                    }

                    RaiseDataBaseError();
                });
            }
        }

        /// <summary>
        /// 发送 Sms 数据。
        /// </summary>
        /// <param name="content">content 参数。</param>
        /// <returns>返回操作结果。</returns>
        /// <exception cref="System.Exception">当执行失败时抛出。</exception>
        /// <example>
        /// <code>
        /// var result = YourObject.SendSms(...);
        /// </code>
        /// </example>
        public static HandleResult SendSms(string content)
        {
            return new HandleResult() { ResultCode=0};
        }

        /// <summary>
        /// 为OrderZhuoTai表创建唯一索引
        /// </summary>
        public void CreateUniqueForOrderZhuoTai()
        {
            if (!UsingSqlServer)
                return;

            bool isCreateIndex = false;
            SqlConnection conn = null;
            SqlCommand cmd = null;
            try
            {
                conn = GetConnection() as SqlConnection;
                cmd = conn.CreateCommand();

                cmd.CommandText = "SELECT SERVERPROPERTY('ProductVersion') AS ProductVersion";

                using (var reader = cmd.ExecuteReader())
                {
                    if (reader.Read())
                    {
                        string productVersion = reader["ProductVersion"].ToString();
                        Console.WriteLine("SQL Server ProductVersion: " + productVersion);

                        // 解析主版本号，例如 "10.50.1600.1" -> 取第一个数字 10
                        string[] parts = productVersion.Split('.');
                        if (parts.Length > 0 && int.TryParse(parts[0], out int majorVersion))
                        {
                            Console.WriteLine($"检测到 SQL Server 主版本号: {majorVersion}");

                            if (majorVersion >= 10)
                            {
                                Console.WriteLine("✅ 当前是 SQL Server 2008 或更高版本，可以使用【过滤唯一索引】方案。");
                                // TODO: 执行创建过滤唯一索引的 SQL
                                isCreateIndex = true;
                            }
                        }
                    }
                }

                if (isCreateIndex)
                    CreateFilteredUniqueIndex(conn);//执行创建过滤唯一索引的 SQL
                else
                    CreateTriggerInstead(conn);//执行创建触发器的 SQL
            }
            catch (Exception e)
            {
                Log.WriteLog("DataManager CreateUniqueForOrderZhuoTai():\r\n" + e.ToString());
                HandleError(e);
                return;
            }
            finally
            {
                if (!object.Equals(null, cmd))
                    cmd.Dispose();
                CloseConnection(conn);
            }
        }

        static void CreateFilteredUniqueIndex(SqlConnection conn)
        {
            // 谓词语义：ZhuoTaiDesc='waimai'（外卖单）不参与防重；其余非外卖单（含 NULL/''）均参与防重。
            // 过滤索引 WHERE 只支持 <列 比较 常量> 的 AND 组合，不支持 OR / NOT IN / 函数（ISNULL/COALESCE），
            // 故不能写 (ZhuoTaiDesc IS NULL OR ZhuoTaiDesc<>'waimai')（SQL Server 会报"关键字 'OR' 附近有语法错误"）；
            // 且 NULL 参与 <> 比较结果为 UNKNOWN，会被过滤掉而漏拦。为此本方法先把存量 NULL 归一为 ''、并补默认约束，
            // 令今后省略该列的 INSERT 落 ''，从而纯 AND 谓词 [ZhuoTaiDesc]<>'waimai' 即可覆盖全部非外卖单。
            // 索引重建：改用新索引名 Index_OrderZhuoTai_ZhuoTaiID_V2；旧名（历史 OR 谓词 / 裸谓词版本）若存在则先 DROP。
            // 已有 V2 索引时整体跳过回填/约束/建索引；不做重复值预检：创建失败仅记日志，下次启动再尝试。
            string indexSql = @"
        -- ① 旧索引名若存在则 DROP（历史 OR 谓词 / 裸谓词版本），改用下方 V2 新名重建
        IF EXISTS (SELECT * FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[OrderZhuoTai]') AND name = N'Index_OrderZhuoTai_ZhuoTaiID')
            DROP INDEX [Index_OrderZhuoTai_ZhuoTaiID] ON [dbo].[OrderZhuoTai];

        -- ②③④ 仅当新索引尚不存在时执行：已有 V2 则无需再回填/补约束/建索引（避免每次启动扫描 OrderZhuoTai）
        IF NOT EXISTS (SELECT * FROM sys.indexes WHERE object_id = OBJECT_ID(N'[dbo].[OrderZhuoTai]') AND name = N'Index_OrderZhuoTai_ZhuoTaiID_V2')
        BEGIN
            -- ② 存量 NULL 归一为 ''，使纯 AND 谓词能覆盖到这些行（幂等：仅更新 NULL 行）
            UPDATE [dbo].[OrderZhuoTai] SET [ZhuoTaiDesc] = '' WHERE [ZhuoTaiDesc] IS NULL;

            -- ③ 补默认约束（幂等）：解决 OrderZhuoTai 插入漏写 ZhuoTaiDesc 的问题——
            --    省略该列的 INSERT 由默认值落 ''（而非 NULL）；按列判断是否存在默认约束
            IF NOT EXISTS (SELECT 1 FROM sys.default_constraints dc
                           INNER JOIN sys.columns c ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
                           WHERE dc.parent_object_id = OBJECT_ID(N'[dbo].[OrderZhuoTai]') AND c.name = N'ZhuoTaiDesc')
                ALTER TABLE [dbo].[OrderZhuoTai] ADD CONSTRAINT [DF_OrderZhuoTai_ZhuoTaiDesc] DEFAULT ('') FOR [ZhuoTaiDesc];

            -- ④ 新索引名建纯 AND 谓词唯一过滤索引
            --    不做重复值预检：若因重复数据创建失败仅记录日志，下次启动会再次尝试创建
            CREATE UNIQUE NONCLUSTERED INDEX [Index_OrderZhuoTai_ZhuoTaiID_V2] ON [dbo].[OrderZhuoTai]
        (
	        [ZhuoTaiID] ASC
        )
        WHERE ([ZhuoTaiID] IS NOT NULL AND [ZhuoTaiID]<>'' AND [ZhuoTaiID]<>'0' AND [ZhuoTaiDesc]<>'waimai')
            WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY];
        END
        ";

            using (SqlCommand cmd = new SqlCommand(indexSql, conn))
            {
                try
                {
                    cmd.ExecuteNonQuery();
                }
                catch (System.Exception ex)
                {
                    Log.WriteLog("创建过滤唯一索引失败: " + ex.Message);
                }
            }
        }

        // 触发器方案（适用于 SQL Server 2000 / 2005，即主版本号 < 10 分支）
        // 演进说明：
        //   ① 早期对外部署过 INSTEAD OF INSERT 触发器（trg_..._Insert）。INSTEAD OF 重台时只 RAISERROR
        //      不写入，属于"语句级失败"——调用方若在整体事务外吞掉异常仍 Commit，会出现"账单在、桌台缺"
        //      的部分提交，破坏多表账单的数据完整性；且其对 ZhuoTaiDesc 用裸谓词 <> 'waimai'，列落 NULL 时
        //      三值逻辑逃逸导致漏拦（扫码绑桌 INSERT 常缺 ZhuoTaiDesc 列，落 NULL）。
        //   ② 现合并为单个 AFTER INSERT, UPDATE 触发器：同一份判定同时覆盖 INSERT（含同批同 ID）与
        //      UPDATE（改号），冲突分支显式 ROLLBACK TRANSACTION，把"重台"升级为"事务级失败"，
        //      外层事务内的其它写入（账单主表等）一并回滚，杜绝部分提交。
        // 存量库升级：外部客户库可能已存在 ① 的 INSTEAD OF 触发器。它与 AFTER 触发器不能共用于同一防重
        // 语义（INSTEAD OF 先于 AFTER 拦截，且只做语句级失败），必须先按旧名 DROP 再创建新名；
        // DROP 均带 IF EXISTS 守卫、幂等，首次迁移后每次启动为空操作。
        static void CreateTriggerInstead(SqlConnection conn)
        {
            string triggerSql = @"
        -- 1) 清理历史触发器（幂等：仅当存在时删除）
        IF EXISTS (SELECT * FROM dbo.sysobjects WHERE id = OBJECT_ID(N'[dbo].[trg_PreventDuplicateNonEmptyZhuoTaiID_Insert]') AND OBJECTPROPERTY(id, N'IsTrigger') = 1)
            DROP TRIGGER [dbo].[trg_PreventDuplicateNonEmptyZhuoTaiID_Insert];

        -- 2) 创建合并后的单个 AFTER INSERT, UPDATE 触发器
        --    空串/'0'/外卖单（ZhuoTaiDesc='waimai'）不参与防重；ZhuoTaiDesc 两侧均用 ISNULL 归一化，
        --    防止列落 NULL 时 <> 'waimai' 三值逻辑逃逸导致漏拦
        IF NOT EXISTS (SELECT * FROM dbo.sysobjects WHERE id = OBJECT_ID(N'[dbo].[trg_PreventDuplicateNonEmptyZhuoTaiID]') AND OBJECTPROPERTY(id, N'IsTrigger') = 1)
        EXEC dbo.sp_executesql @statement = N'CREATE TRIGGER [dbo].[trg_PreventDuplicateNonEmptyZhuoTaiID]
        ON [dbo].[OrderZhuoTai]
        AFTER INSERT, UPDATE
        AS
        BEGIN
            SET NOCOUNT ON;

            -- 检查：本次写入（含批量 INSERT 同 ID、UPDATE 改号）是否出现 ZhuoTaiID 与其它行重复
            IF EXISTS (
                SELECT 1
                FROM inserted i
                WHERE
                    i.ZhuoTaiID IS NOT NULL
                    AND i.ZhuoTaiID <> ''''             -- 非空字符串
                    AND i.ZhuoTaiID <> ''0''
                    AND ISNULL(i.ZhuoTaiDesc, '''') <> ''waimai''  -- NULL 视同非外卖单，防三值逻辑逃逸
                    AND EXISTS (                      -- 表中存在其它行（非本行自身）占用该值
                        SELECT 1
                        FROM OrderZhuoTai u
                        WHERE u.ZhuoTaiID = i.ZhuoTaiID
                          AND u.UID <> i.UID
                          AND ISNULL(u.ZhuoTaiDesc, '''') <> ''waimai''
                    )
            )
            BEGIN
                -- AFTER 触发器必须显式回滚：把冲突升级为整个事务失败，
                -- 防止调用方把其它语句照常 Commit 造成「账单在、桌台缺」的部分提交
                ROLLBACK TRANSACTION;
                RAISERROR(''插入或更新失败：ZhuoTaiID 值不允许重复。'', 16, 1);
                RETURN;
            END
        END' ;
        ";

            using (SqlCommand cmd = new SqlCommand(triggerSql, conn))
            {
                try
                {
                    cmd.ExecuteNonQuery();
                }
                catch (System.Exception ex)
                {
                    Log.WriteLog("创建触发器失败(CreateTriggerInstead): " + ex.Message);
                }
            }
        }
    }

}











