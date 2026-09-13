import org.limine.entry.tool.processes.JsonOutput;
import org.limine.entry.tool.processes.ManagedJson;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

public class ManagedJsonContract {
    private static int passed;

    private static void reject(String name, byte[] input) throws Exception {
        boolean rejected = false;
        try {
            ManagedJson.read(input);
        } catch (IOException expected) {
            rejected = true;
        }
        if (!rejected) throw new AssertionError("Accepted invalid managed JSON: " + name);
        passed++;
    }

    private static void reject(String name, String input) throws Exception {
        reject(name, input.getBytes(StandardCharsets.UTF_8));
    }

    public static void main(String[] args) throws Exception {
        Map<String, Object> expected = new java.util.LinkedHashMap<>();
        expected.put("schema", 1L);
        expected.put("enabled", true);
        expected.put("missing", null);
        expected.put("path", "/fixture/é/\"line\n😀");
        expected.put("steps", List.of(Map.of("number", Long.MIN_VALUE), Map.of("number", Long.MAX_VALUE)));
        if (!ManagedJson.read(JsonOutput.encode(expected).getBytes(StandardCharsets.UTF_8)).equals(expected)) {
            throw new AssertionError("Typed JSON/Unicode round trip differs");
        }
        passed++;
        reject("empty", "");
        reject("array root", "[]");
        reject("trailing document", "{} {}");
        reject("duplicate", "{\"x\":null,\"x\":1}");
        reject("nested duplicate", "{\"x\":{\"y\":0,\"y\":1}}");
        reject("fraction", "{\"x\":1.0}");
        reject("exponent", "{\"x\":1e0}");
        reject("overflow", "{\"x\":9223372036854775808}");
        reject("comment", "{/* x */\"x\":1}");
        reject("trailing comma", "{\"x\":1,}");
        reject("incomplete object", "{\"x\":");
        reject("incomplete array", "{\"x\":[");
        reject("unpaired high surrogate", "{\"x\":\"\\ud800\"}");
        reject("unpaired low surrogate", "{\"x\":\"\\udc00\"}");
        reject("UTF-8", new byte[]{'{', '"', 'x', '"', ':', '"', (byte) 0xff, '"', '}'});
        reject("depth", "{\"x\":" + "[".repeat(65) + "0" + "]".repeat(65) + "}");
        reject("property length", "{\"" + "x".repeat(257) + "\":0}");
        reject("string length", "{\"x\":\"" + "x".repeat(1024 * 1024 + 1) + "\"}");
        reject("token count", "{\"x\":[" + "0,".repeat(65536) + "0]}");
        reject("document bytes", new byte[ManagedJson.MAX_BYTES + 1]);
        boolean failedRead = false;
        try {
            ManagedJson.read(new InputStream() {
                int position;
                @Override public int read() throws IOException {
                    if (position < 2) return "{}".charAt(position++);
                    throw new IOException("fixture read failure after a valid prefix");
                }
            });
        } catch (IOException expectedFailure) {
            failedRead = true;
        }
        if (!failedRead) throw new AssertionError("Read failure became a complete document");
        passed++;
        System.out.println("Passed " + passed + " managed JSON contracts.");
    }
}
