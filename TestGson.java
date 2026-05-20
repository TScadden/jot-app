import com.google.gson.Gson;
public class TestGson {
    public static void main(String[] args) {
        try {
            new Gson().fromJson("[] a", Object.class);
        } catch (Exception e) {
            System.out.println(e.getMessage());
        }
    }
}
