import org.limine.entry.tool.processes.JsonOutput;
import org.limine.entry.tool.processes.ManagedChannel;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;

public class ManagedChannelContract {
    private static final String ID = "11111111-1111-4111-8111-111111111111";

    private static Map<String, Object> response() {
        return new LinkedHashMap<>(Map.of("format", "omasecboot-producer-response", "schema", 1L,
                "invocation", ID, "sequence", 1L, "ok", true, "payload", Map.of("accepted", true)));
    }

    private static void reject(String encoded) throws Exception {
        boolean refused = false;
        try (ManagedChannel channel = new ManagedChannel(ID,
                new ByteArrayInputStream(encoded.getBytes(StandardCharsets.UTF_8)), new ByteArrayOutputStream())) {
            channel.exchange(Map.of("operation", "fixture"));
        } catch (IOException expected) {
            refused = true;
        }
        if (!refused) throw new AssertionError("Accepted unmatched/incomplete producer response");
    }

    public static void main(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("pipes")) {
            if (!"fixture interactive input".equals(new java.io.BufferedReader(new java.io.InputStreamReader(System.in)).readLine())) {
                throw new AssertionError("Protocol channel replaced the user input stream");
            }
            if (!Files.exists(Path.of("/proc/self/fd/200"))) throw new AssertionError("Worker lost the inherited lock descriptor");
            int child = new ProcessBuilder("/usr/bin/bash", "-c", "test -e /proc/self/fd/200").start().waitFor();
            if (child == 0) throw new AssertionError("Fixture no longer demonstrates Java child descriptor closure");
            try (ManagedChannel channel = ManagedChannel.inherited(ID)) {
                if (!Boolean.TRUE.equals(channel.exchange(Map.of("operation", "hello", "pid", ProcessHandle.current().pid())).get("accepted"))) {
                    throw new AssertionError("Broker did not acknowledge worker");
                }
                channel.exchange(Map.of("operation", "complete"));
            }
            System.out.println("Passed inherited-pipe and Java-child descriptor contract.");
            return;
        }
        ByteArrayOutputStream request = new ByteArrayOutputStream();
        try (ManagedChannel channel = new ManagedChannel(ID,
                new ByteArrayInputStream((JsonOutput.encode(response()) + "\n").getBytes(StandardCharsets.UTF_8)), request)) {
            if (!channel.exchange(Map.of("operation", "fixture")).equals(Map.of("accepted", true))) {
                throw new AssertionError("Channel payload changed");
            }
        }
        if (!request.toString(StandardCharsets.UTF_8).contains("omasecboot-producer-request")) throw new AssertionError("Missing request frame");
        Map<String, Object> changed = response(); changed.put("sequence", 2L); reject(JsonOutput.encode(changed) + "\n");
        changed = response(); changed.put("invocation", "22222222-2222-4222-8222-222222222222"); reject(JsonOutput.encode(changed) + "\n");
        changed = response(); changed.put("ok", false); reject(JsonOutput.encode(changed) + "\n");
        changed = response(); changed.put("extra", true); reject(JsonOutput.encode(changed) + "\n");
        reject(JsonOutput.encode(response()));
        reject("");
        System.out.println("Passed 7 producer-channel framing contracts.");
    }
}
