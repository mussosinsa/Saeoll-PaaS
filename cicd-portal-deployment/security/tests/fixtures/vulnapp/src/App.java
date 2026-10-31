import java.sql.*;
import java.security.MessageDigest;
public class App {
  void run(Connection conn, Statement stmt, String name) throws Exception {
    ResultSet rs = stmt.executeQuery("SELECT * FROM users WHERE name = '" + name + "'");
    PreparedStatement ps = conn.prepareStatement("SELECT * FROM users WHERE name = ?");
    Runtime.getRuntime().exec(name);
    MessageDigest md = MessageDigest.getInstance("MD5");
  }
}
