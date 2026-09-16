import org.limine.entry.tool.processes.ManagedChannel;
import org.limine.entry.tool.processes.ManagedAddition;
import org.limine.entry.tool.processes.CorePublicationAuthority;
import org.limine.entry.tool.processes.BootResources;
import org.limine.entry.tool.processes.JsonOutput;
import org.limine.entry.tool.processes.ManagedJson;
import org.limine.entry.tool.processes.FileState;
import org.limine.entry.tool.processes.PreparedPublicationCodec;
import org.limine.entry.tool.processes.LimineReader;
import org.limine.entry.tool.processes.LimineManager;
import org.limine.entry.tool.processes.LimineWriter;
import org.limine.entry.tool.processes.PreparedPublication;
import java.io.IOException;
import org.limine.entry.tool.objects.Config;
import org.limine.entry.tool.objects.EntryOptions;

import java.io.BufferedReader;
import java.io.FileInputStream;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.List;
import java.util.Arrays;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.nio.file.StandardCopyOption;
import java.util.concurrent.TimeUnit;

/** Synchronous actual-Java peer for the production Core broker, not a boot publisher. */
public class ProducerSessionContract {
    private static final String INVOCATION = "11111111-1111-4111-8111-111111111111";
    private static void raw(String text, boolean hold) throws Exception {
        try (var output = new FileOutputStream("/proc/self/fd/198")) {
            output.write(text.getBytes(StandardCharsets.UTF_8)); output.flush();
            if (hold) new FileInputStream("/proc/self/fd/199").read();
        }
    }
    private static String frame(String invocation, int sequence, String payload) {
        return "{\"format\":\"omasecboot-producer-request\",\"schema\":1,\"invocation\":\"" + invocation
                + "\",\"sequence\":" + sequence + ",\"payload\":" + payload + "}\n";
    }
    public static void main(String[] args) throws Exception {
        String mode = args[0];
        if (mode.equals("describe-publish")) { System.out.println(JsonOutput.encode(fixtureIntent(args[1]))); return; }
        if (mode.equals("ordinary-publish")) { ordinary(args[1]); return; }
        String input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8)).readLine();
        if (!"fixture user input".equals(input)) throw new AssertionError("RPC consumed user stdin");
        System.out.println("UI: " + input);
        if (mode.equals("publish-prepare")) {
            if (args[1].equals("publish-intent-match-model")) {
                Map<String, Object> alternate = ManagedJson.read(Files.readAllBytes(Path.of("/work/alternate-intent.json")));
                try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) {
                    channel.exchange(Map.of("operation", "match-intent", "intent", alternate));
                    throw new AssertionError("Core accepted memory/wire model B against durable intent A");
                }
            }
            if (args[1].startsWith("publish-context-native-")) {
                Map<String, Object> selected = new LinkedHashMap<>(fixtureIntent(args[1]));
                if (args[1].equals("publish-context-native-machine")) {
                    Map<?, ?> publication = (Map<?, ?>) selected.get("publication");
                    Map<String, Object> model = new LinkedHashMap<>(ManagedJson.read(
                            ((String) publication.get("model")).getBytes(StandardCharsets.UTF_8)));
                    model.put("machine_id", "22222222222222222222222222222222");
                    selected.put("publication", Map.of("kind", "addition", "model", JsonOutput.encode(model)));
                } else if (args[1].equals("publish-context-native-path")) {
                    Map<?, ?> configuration = (Map<?, ?>) selected.get("configuration");
                    selected.put("configuration", Map.of("path", "/boot/other.conf", "sha256", configuration.get("sha256")));
                } else throw new AssertionError("Unknown native context fixture");
                try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) {
                    channel.exchange(Map.of("operation", "match-intent", "intent", selected));
                    throw new AssertionError("Core accepted native intent outside the captured context");
                }
            }
            if (args[1].startsWith("publish-mkdir-collision-")) {
                try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) {
                    channel.exchange(Map.of("operation", "match-intent", "intent", fixtureIntent(args[1])));
                    throw new AssertionError("Core accepted a conflicting complete target set");
                }
            }
            try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) { addition(args[1]).prepare(channel, INVOCATION); }
            return;
        }
        if (mode.equals("publish-apply")) {
            if (args[1].equals("publish-native-namespace")) { namespaceChange(); System.exit(19); }
            if (args[1].equals("publish-native-final-third-state") || args[1].equals("publish-core-death-final-third-state")) {
                finalTargetBoundary(args[1].equals("publish-core-death-final-third-state"));
                System.exit(19);
            }
            if (args[1].equals("publish-core-death") || args[1].equals("publish-core-death-directory-bind")
                    || args[1].equals("publish-native-directory-bind") || args[1].equals("publish-native-stage-bind")) {
                lateBoundary(args[1]);
                if (!args[1].equals("publish-core-death")) System.exit(19);
                return;
            }
            if (args[1].equals("publish-unstarted-after")) {
                try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) {
                    Map<String, Object> application = channel.exchange(Map.of("operation", "application"));
                    var plan = PreparedPublicationCodec.decode(JsonOutput.encode(application.get("plan")).getBytes(StandardCharsets.UTF_8));
                    var put = plan.puts().getFirst();
                    // Deliberately violate the producer contract to test Core's
                    // independent before-frontier enforcement.
                    Path stage;
                    try (var paths = Files.list(put.target().getParent())) {
                        stage = paths.filter(path -> {
                            try { return FileState.capture(path).same(put.after()); } catch (Exception ignored) { return false; }
                        }).findFirst().orElseThrow();
                    }
                    Files.move(stage, put.target(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                    channel.exchange(Map.of("operation", "before", "id", put.id(), "state", PreparedPublicationCodec.state(put.after())));
                    throw new AssertionError("Core accepted an unstarted after-state");
                }
            }
            try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) { new CorePublicationAuthority(channel).apply(); }
            if (args[1].equals("publish-late-failure")) System.exit(19);
            return;
        }
        if (mode.startsWith("retain-")) {
            if (mode.equals("retain-source-drift")) Files.writeString(Path.of("/work/input"), "changed after intent");
            if (mode.equals("retain-fifo")) {
                Files.delete(Path.of("/work/input"));
                if (new ProcessBuilder("/usr/bin/mkfifo", "/work/input").start().waitFor() != 0) throw new AssertionError("FIFO fixture failed");
            }
            if (mode.equals("retain-growing")) Files.writeString(Path.of("/work/grow-source"), "armed");
            try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) {
                if (!mode.equals("retain-incomplete")) {
                    Map<String, Object> retained = channel.exchange(Map.of("operation", "retain", "id", "image"));
                    if (!retained.equals(channel.exchange(Map.of("operation", "retain", "id", "image")))) {
                        throw new AssertionError("Repeated retention changed its immutable result");
                    }
                    if (mode.equals("retain-kernel") || mode.equals("retain-bytes")) {
                        channel.exchange(Map.of("operation", "retain", "id", "initrd"));
                    }
                }
                channel.exchange(Map.of("operation", "complete"));
                if (mode.equals("retain-nonzero")) System.exit(19);
            }
            return;
        }
        if (mode.equals("hang")) { Thread.sleep(300000); return; }
        if (mode.equals("backpressure") || mode.equals("backpressure-interrupt")) {
            raw(frame(INVOCATION, 1, "{\"operation\":\"hello\"}"), false);
            Thread.sleep(300000); return;
        }
        if (mode.equals("raw-nul")) {
            raw(frame(INVOCATION, 1, "{\"operation\":\"hel\u0000lo\"}"), true); return;
        }
        if (mode.equals("duplicate-key")) {
            raw(frame(INVOCATION, 1, "{\"operation\":\"hello\",\"operation\":\"complete\"}"), true); return;
        }
        try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) {
            channel.exchange(Map.of("operation", "hello", "pid", ProcessHandle.current().pid()));
            if (mode.equals("hang-after-hello")) { Thread.sleep(300000); return; }
            Files.delete(Path.of("/work/pinned"));
            switch (mode) {
                case "no-complete" -> { return; }
                case "wrong-sequence" -> { raw(frame(INVOCATION, 99, "{\"operation\":\"complete\"}"), true); return; }
                case "wrong-invocation" -> { raw(frame("22222222-2222-4222-8222-222222222222", 2, "{\"operation\":\"complete\"}"), true); return; }
                case "unknown-request" -> { channel.exchange(Map.of("operation", "unknown")); return; }
                default -> { }
            }
            channel.exchange(Map.of("operation", "complete"));
            if (mode.equals("nonzero-after-complete")) System.exit(19);
            if (mode.equals("trailing-invalid")) raw("{\"unfinished\":", false);
            if (mode.equals("trailing-frame")) raw(frame(INVOCATION, 3, "{\"operation\":\"hello\"}"), false);
            if (mode.equals("close-and-hang")) {
                channel.close();
                // Test-only access closes the original inherited descriptor,
                // not merely another open of its /proc/self/fd pathname.
                FileDescriptor original = new FileDescriptor();
                var field = FileDescriptor.class.getDeclaredField("fd");
                field.setAccessible(true); field.setInt(original, 198);
                new FileOutputStream(original).close();
                Thread.sleep(300000);
            }
        }
    }

    private static boolean kernelCase(String mode) {
        return mode.equals("publish-linux") || mode.equals("publish-mkdir-linux") || mode.startsWith("publish-mkdir-collision-");
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> fixtureIntent(String mode) throws Exception {
        Map<String, Object> intent = new LinkedHashMap<>(addition(mode).intent());
        if (mode.startsWith("publish-mkdir-collision-")) {
            List<Map<String, Object>> resources = new ArrayList<>();
            for (Object resource : (List<?>) intent.get("resources")) resources.add(new LinkedHashMap<>((Map<String, Object>) resource));
            String first = (String) resources.getFirst().get("target");
            switch (mode) {
                case "publish-mkdir-collision-target" -> resources.get(1).put("target", first);
                case "publish-mkdir-collision-ancestor" -> resources.get(1).put("target", first + "/child");
                case "publish-mkdir-collision-config" -> resources.getFirst().put("target", "/boot/limine.conf");
                default -> throw new AssertionError("Unknown collision fixture");
            }
            intent.put("resources", resources);
        }
        return intent;
    }

    private static ManagedAddition addition(String mode) throws Exception {
        Config.QUIET = true; Config.ENABLE_VERIFICATION = mode.equals("publish-efi-hash"); Config.UKI_FILE_PREFIX = "contract";
        Config config = new Config("11111111111111111111111111111111", "Contract Linux", "/boot", "boot():");
        BootResources.Addition addition = kernelCase(mode)
                ? BootResources.kernel(config, "linux", "", "/work/initrd", "/work/input", "root=fixture quiet")
                : BootResources.uki(config, "contract", "linux", "/work/input", "root=fixture quiet");
        return new ManagedAddition(config, addition, "fixture addition", new EntryOptions());
    }

    @SuppressWarnings("unchecked")
    private static void ordinary(String mode) throws Exception {
        Config.QUIET = true; Config.ENABLE_VERIFICATION = kernelCase(mode) || mode.equals("publish-efi-hash");
        Config.UKI_FILE_PREFIX = "contract";
        Config config = new Config("11111111111111111111111111111111", "Contract Linux", "/work/ordinary", "boot():");
        Files.createDirectories(Path.of(config.espPath()));
        Files.copy(Path.of("/work/config-before"), Path.of(config.espPath(), "limine.conf"));
        Files.createDirectories(Path.of("/work/ordinary-inputs"));
        Map<String, Object> stages = ManagedJson.read(Files.readAllBytes(Path.of("/work/stages.json")));
        Map<String, Object> intent = ManagedJson.read(Files.readAllBytes(Path.of("/work/admitted-intent.json")));
        for (Object value : (List<?>) intent.get("resources")) {
            Map<String, Object> resource = (Map<String, Object>) value;
            Map<String, Object> stage = (Map<String, Object>) stages.get(resource.get("id"));
            Map<String, Object> retained = (Map<String, Object>) stage.get("retained");
            Files.copy(Path.of((String) retained.get("path")), Path.of("/work/ordinary-inputs", Path.of((String) resource.get("source")).getFileName().toString()));
        }
        LimineReader reader = new LimineReader(config);
        LimineManager manager = new LimineManager(reader.getTargetOsNode(), config, Map.of("default", "root=fixture quiet"));
        if (kernelCase(mode)) manager.addKernel("linux", "fixture addition", new EntryOptions(), "/work/ordinary-inputs/initrd", "/work/ordinary-inputs/input", "");
        else manager.addUki("linux", "fixture addition", new EntryOptions(), "/work/ordinary-inputs/input");
        byte[] expected = (String.join("\n", new LimineWriter(config).render(reader.getRootNode())) + "\n").getBytes(StandardCharsets.UTF_8);
        byte[] actual = Files.readAllBytes(Path.of("/boot/limine.conf"));
        if ("parity".equals(System.getenv("ORACLE_FAULT")) || !Arrays.equals(expected, actual)) throw new AssertionError("Managed and ordinary rendering differ");
        Files.writeString(Path.of("/work/parity-verified"), "actual ordinary renderer matches managed bytes");
    }

    private static void fixtureCommand(String... command) throws IOException {
        try {
            int status = new ProcessBuilder(command).inheritIO().start().waitFor();
            if (status != 0) throw new IOException("Fixture command failed (capability failure is a blocker): " + Arrays.toString(command) + ": " + status);
        } catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new IOException(e); }
    }

    @SuppressWarnings("unchecked")
    private static void verifyInheritedPins(Map<String, Object> application) throws IOException {
        List<?> pins = (List<?>) application.get("pins");
        if (pins.isEmpty()) throw new AssertionError("No inherited custody to exercise");
        for (Object value : pins) {
            Map<String, Object> pin = (Map<String, Object>) value;
            FileState expected = PreparedPublicationCodec.readState((Map<String, Object>) pin.get("state"));
            if (!expected.same(FileState.descriptor(((Long) pin.get("fd")).intValue()))) {
                throw new AssertionError("Inherited byte/inode custody changed: " + pin.get("fd"));
            }
        }
        Files.writeString(Path.of("/work/custody-proof"), JsonOutput.encode(application.get("pins")));
    }

    private static void unchangedMountObjects() throws IOException {
        fixtureCommand("/fixtures/mount-custody", "snapshot", "final");
        if (!Arrays.equals(Files.readAllBytes(Path.of("/work/mount-witness-prepared")),
                Files.readAllBytes(Path.of("/work/mount-witness-final")))) {
            throw new AssertionError("Refusal changed a stage/configuration/target inode or bytes");
        }
    }

    private static void namespaceChange() throws Exception {
        try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) {
            // The application exchange proves the actual bound worker was admitted.
            Map<String, Object> application = channel.exchange(Map.of("operation", "application"));
            verifyInheritedPins(application);
            String before = Files.readString(Path.of("/work/worker-namespace-before")).strip();
            String after = Files.readSymbolicLink(Path.of("/proc/self/ns/mnt")).toString();
            long pid = ProcessHandle.current().pid();
            Map<String, Object> launch = ManagedJson.read(Files.readAllBytes(Path.of("/work/publication-launch.json")));
            if (!before.equals(application.get("mount_namespace")) || before.equals(after)
                    || pid != Long.parseLong(Files.readString(Path.of("/work/worker-exec-pid")).strip())
                    || !((Map<?, ?>) launch.get("worker")).get("pid").equals(pid)) {
                throw new AssertionError("unshare did not exec the same bound worker into a new mount namespace");
            }
            Files.writeString(Path.of("/work/namespace-proof.json"), JsonOutput.encode(Map.of(
                    "before", before, "after", after, "same_pid", true, "inherited_pins", true)));
            boolean refused = false;
            try { new CorePublicationAuthority(channel).apply(); }
            catch (IOException expected) {
                if (!"Publication mount namespace changed".equals(expected.getMessage())) throw expected;
                Files.writeString(Path.of("/work/native-mount-refused.json"), JsonOutput.encode(Map.of(
                        "reason", expected.getMessage(), "boundary", "worker-exec", "applied_calls", 0)));
                refused = true;
            }
            if (!refused) throw new AssertionError("Native authority accepted a foreign mount namespace");
            verifyInheritedPins(application);
            unchangedMountObjects();
        }
    }

    private static String freshMountId(Path path) throws IOException {
        // Read-only independent fresh-FD witness, entirely within the fixture namespace.
        String script = """
                set -euo pipefail
                exec 3<"$1"
                [[ $1 -ef /proc/self/fd/3 ]]
                mount=''
                while IFS= read -r line; do
                    if [[ $line == mnt_id:* ]]; then
                        [[ -z $mount && $line =~ ^mnt_id:[[:blank:]]+([1-9][0-9]*)$ ]]
                        mount=${BASH_REMATCH[1]}
                    fi
                done </proc/self/fdinfo/3
                [[ -n $mount && $1 -ef /proc/self/fd/3 ]]
                printf '%s\\n' "$mount"
                """;
        Process observer = new ProcessBuilder("/usr/bin/bash", "--noprofile", "--norc", "-p", "-c", script,
                "fixture-target-mount", path.toString()).redirectError(ProcessBuilder.Redirect.INHERIT).start();
        try {
            if (!observer.waitFor(5, TimeUnit.SECONDS)) {
                observer.destroyForcibly();
                throw new IOException("Fixture mount observation timed out");
            }
            String result = new String(observer.getInputStream().readAllBytes(), StandardCharsets.UTF_8).strip();
            if (observer.exitValue() != 0 || !result.matches("[1-9][0-9]*")) throw new IOException("Fixture mount observation failed");
            return result;
        } catch (InterruptedException e) { observer.destroyForcibly(); Thread.currentThread().interrupt(); throw new IOException(e); }
    }

    private static Map<String, Object> preservedObjects(PreparedPublication plan, PreparedPublication.Stage stage) throws IOException {
        return Map.of("stage", Map.of("path", stage.path().toString(), "state", PreparedPublicationCodec.state(FileState.capture(stage.path()))),
                "configuration", Map.of("path", plan.configuration().target().toString(),
                        "state", PreparedPublicationCodec.state(FileState.capture(plan.configuration().target()))));
    }

    private static void finalTargetBoundary(boolean death) throws Exception {
        try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) {
            CorePublicationAuthority core = new CorePublicationAuthority(channel);
            Map<String, Object> application = ManagedJson.read(Files.readAllBytes(Path.of("/work/application.json")));
            PreparedPublication plan = PreparedPublicationCodec.decode(JsonOutput.encode(application.get("plan")).getBytes(StandardCharsets.UTF_8));
            PreparedPublication.Put first = plan.puts().getFirst();
            if (!first.before().kind().equals(death ? "file" : "absent")) throw new AssertionError("Wrong original target fixture state");
            String expectedMount = ((List<?>) application.get("directories")).stream().map(value -> (Map<?, ?>) value)
                    .filter(directory -> first.target().getParent().toString().equals(directory.get("path")))
                    .map(directory -> (String) directory.get("mount_id")).findFirst().orElseThrow();
            long supervisor = ProcessHandle.current().parent().orElseThrow().pid();
            PreparedPublication.Stage[] staged = {null};
            FileState[] foreign = {null};
            boolean[] armed = {false}, firstPassed = {false}, refusedLocally = {false}, killed = {false};
            int[] localCalls = {0}, appliedCalls = {0}, firstLine = {0};
            PreparedPublication.Authority wrapper = new PreparedPublication.Authority() {
                private void beforeRpc() {
                    if (armed[0]) throw new AssertionError("RPC/effect callback after final pending frontier");
                }
                public void verifyLive() throws IOException {
                    if (!armed[0]) { core.verifyLive(); return; }
                    int call = ++localCalls[0];
                    StackTraceElement site = StackWalker.getInstance().walk(frames -> frames
                            .filter(frame -> frame.getClassName().equals(PreparedPublication.class.getName()) && frame.getMethodName().equals("applyPut"))
                            .findFirst().orElseThrow().toStackTraceElement());
                    if (call > 2 || !first.before().same(FileState.capture(first.target()))
                            || !staged[0].state().same(FileState.capture(staged[0].path()))) {
                        throw new AssertionError("Injection missed exact before/stage states at final local check");
                    }
                    boolean alive = ProcessHandle.of(supervisor).map(ProcessHandle::isAlive).orElse(false);
                    if (alive == death) throw new AssertionError("Wrong Core lifetime at final local check");
                    if (call == 2) {
                        if (!firstPassed[0] || site.getLineNumber() <= firstLine[0]) throw new AssertionError("Final check did not follow the first local check");
                        Files.writeString(Path.of("/work/third-state-preserved-before.json"), JsonOutput.encode(preservedObjects(plan, staged[0])));
                        String mount = freshMountId(first.target().getParent());
                        if (!mount.equals(expectedMount) || !mount.equals(freshMountId(staged[0].path()))) throw new AssertionError("Stage is not on original target parent mount");
                        if (first.before().kind().equals("file") && !mount.equals(freshMountId(first.target()))) throw new AssertionError("Original target mount differs");
                        Path temporary = Files.createTempFile(first.target().getParent(), ".third-state-", ".tmp");
                        Files.writeString(Path.of("/work/third-state-foreign-bytes"), "foreign final-check target\n");
                        Files.writeString(temporary, "foreign final-check target\n");
                        Files.move(temporary, first.target(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                        foreign[0] = FileState.capture(first.target());
                        if (!foreign[0].kind().equals("file") || foreign[0].identity().equals(first.before().identity())
                                || foreign[0].identity().equals(staged[0].state().identity()) || foreign[0].sameContent(first.after())
                                || !mount.equals(freshMountId(first.target())) || !mount.equals(freshMountId(first.target().getParent()))
                                || !application.get("mount_namespace").equals(Files.readSymbolicLink(Path.of("/proc/self/ns/mnt")).toString())) {
                            throw new AssertionError("Third-state injection did not preserve the mount and contrast object identities");
                        }
                        verifyInheritedPins(application);
                        Files.writeString(Path.of("/work/third-state-boundary.json"), JsonOutput.encode(Map.of(
                                "target", first.target().toString(), "before", PreparedPublicationCodec.state(first.before()),
                                "authorized_after", PreparedPublicationCodec.state(first.after()), "foreign", PreparedPublicationCodec.state(foreign[0]),
                                "local_call", call, "first_local_passed", firstPassed[0], "core_alive", alive,
                                "site", Map.of("method", site.getClassName() + "." + site.getMethodName(), "first_line", firstLine[0], "final_line", site.getLineNumber()),
                                "mount", Map.of("expected", expectedMount, "parent", mount, "stage", freshMountId(staged[0].path()), "target", freshMountId(first.target()),
                                        "namespace", application.get("mount_namespace")))));
                    }
                    try { core.verifyLive(); }
                    catch (IOException expected) {
                        if (call != 2 || foreign[0] == null || !("Publication target left its pinned before/after states: " + first.target()).equals(expected.getMessage())) throw expected;
                        if (ProcessHandle.of(supervisor).map(ProcessHandle::isAlive).orElse(false) != alive) throw new AssertionError("Core lifetime changed during final target refusal");
                        Files.writeString(Path.of("/work/native-target-refused.json"), JsonOutput.encode(Map.of(
                                "reason", expected.getMessage(), "local_call", call, "core_alive", alive, "applied_calls", appliedCalls[0])));
                        refusedLocally[0] = true;
                        throw expected;
                    }
                    if (call == 1) {
                        firstPassed[0] = true;
                        firstLine[0] = site.getLineNumber();
                        Files.writeString(Path.of("/work/third-state-first-local.json"), JsonOutput.encode(Map.of(
                                "local_call", call, "target", PreparedPublicationCodec.state(FileState.capture(first.target())), "core_alive", alive)));
                    }
                }
                public void validate(PreparedPublication value) throws IOException { beforeRpc(); core.validate(value); }
                public PreparedPublication.Frontier frontier(String id) throws IOException {
                    beforeRpc();
                    PreparedPublication.Frontier result = core.frontier(id);
                    if (staged[0] != null) {
                        if (!id.equals(first.id()) || !result.phase().equals("pending") || !staged[0].state().same(result.observed())
                                || !first.before().same(FileState.capture(first.target())) || appliedCalls[0] != 0) {
                            throw new AssertionError("Did not reach the last authorized stage frontier");
                        }
                        Files.writeString(Path.of("/work/third-state-frontier.json"), JsonOutput.encode(Map.of(
                                "id", id, "phase", result.phase(), "observed", PreparedPublicationCodec.state(result.observed()),
                                "target", PreparedPublicationCodec.state(FileState.capture(first.target())), "local_calls", 0)));
                        Files.write(Path.of("/work/third-state-requests-before"), Files.readAllBytes(Path.of("/work/publication-requests.jsonl")));
                        if (death) {
                            fixtureCommand("/usr/bin/kill", "-KILL", Long.toString(supervisor));
                            try { while (ProcessHandle.of(supervisor).map(ProcessHandle::isAlive).orElse(false)) Thread.sleep(5); }
                            catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new IOException(e); }
                            killed[0] = true;
                        }
                        verifyInheritedPins(application);
                        Files.writeString(Path.of("/work/third-state-core.json"), JsonOutput.encode(Map.of(
                                "killed", killed[0], "alive", ProcessHandle.of(supervisor).map(ProcessHandle::isAlive).orElse(false), "pins_survived", true)));
                        armed[0] = true;
                    }
                    return result;
                }
                public void before(String id, FileState state) throws IOException { beforeRpc(); core.before(id, state); }
                public PreparedPublication.Stage stage(PreparedPublication.Put put) throws IOException { beforeRpc(); staged[0] = core.stage(put); return staged[0]; }
                public void applied(String id, FileState state) throws IOException { appliedCalls[0]++; beforeRpc(); core.applied(id, state); }
            };
            try { plan.apply(wrapper); throw new AssertionError("Foreign target was accepted"); }
            catch (IOException expected) {
                if (!refusedLocally[0] || !("Publication target left its pinned before/after states: " + first.target()).equals(expected.getMessage())) throw expected;
            }
            if (localCalls[0] != 2 || appliedCalls[0] != 0 || killed[0] != death || !foreign[0].same(FileState.capture(first.target()))
                    || !staged[0].state().same(FileState.capture(staged[0].path()))
                    || !plan.configuration().before().same(FileState.capture(plan.configuration().target()))) {
                throw new AssertionError("Target refusal overwrote foreign bytes or changed pinned stage/configuration");
            }
            verifyInheritedPins(application);
            Files.write(Path.of("/work/third-state-requests-after"), Files.readAllBytes(Path.of("/work/publication-requests.jsonl")));
            if (!Arrays.equals(Files.readAllBytes(Path.of("/work/third-state-requests-before")),
                    Files.readAllBytes(Path.of("/work/third-state-requests-after")))) throw new AssertionError("Final local target guard used RPC");
            Files.writeString(Path.of("/work/third-state-preserved-after.json"), JsonOutput.encode(preservedObjects(plan, staged[0])));
            Files.writeString(Path.of("/work/third-state-final.json"), JsonOutput.encode(Map.of(
                    "target", PreparedPublicationCodec.state(FileState.capture(first.target())), "local_calls", localCalls[0], "applied_calls", appliedCalls[0])));
            if (death) {
                Files.writeString(Path.of("/work/publication-result"), "1\n");
                Files.writeString(Path.of("/work/after-core-death"), "foreign target preserved by final local target-state guard");
            }
        }
    }

    private static void lateBoundary(String mode) throws Exception {
        boolean death = mode.startsWith("publish-core-death");
        boolean bind = !mode.equals("publish-core-death");
        try (ManagedChannel channel = ManagedChannel.inherited(INVOCATION)) {
            CorePublicationAuthority core = new CorePublicationAuthority(channel);
            Map<String, Object> application = ManagedJson.read(Files.readAllBytes(Path.of("/work/application.json")));
            PreparedPublication plan = PreparedPublicationCodec.decode(JsonOutput.encode(application.get("plan")).getBytes(StandardCharsets.UTF_8));
            long supervisor = ProcessHandle.current().parent().orElseThrow().pid();
            PreparedPublication.Put first = plan.puts().getFirst();
            PreparedPublication.Stage[] staged = {null};
            boolean[] injected = {false}, killed = {false}, localRefusal = {false};
            int[] appliedCalls = {0};
            Path[] boundPath = {null};
            PreparedPublication.Authority wrapper = new PreparedPublication.Authority() {
                private void beforeRpc() {
                    if (bind && injected[0]) throw new AssertionError("RPC/effect callback after last authorized frontier, before local mount refusal");
                }
                public void verifyLive() throws IOException {
                    try { core.verifyLive(); }
                    catch (IOException expected) {
                        if (bind && injected[0] && ("Fresh pathname differs from held mount/object custody: " + boundPath[0]).equals(expected.getMessage())) {
                            boolean alive = ProcessHandle.of(supervisor).map(ProcessHandle::isAlive).orElse(false);
                            if (alive == death || appliedCalls[0] != 0) throw new AssertionError("Wrong local-guard boundary");
                            Files.writeString(Path.of("/work/native-mount-refused.json"), JsonOutput.encode(Map.of(
                                    "reason", expected.getMessage(), "boundary", "after-last-pending-frontier", "path", boundPath[0].toString(),
                                    "core_alive", alive, "applied_calls", appliedCalls[0])));
                            localRefusal[0] = true;
                        }
                        throw expected;
                    }
                }
                public void validate(PreparedPublication value) throws IOException { beforeRpc(); core.validate(value); }
                public PreparedPublication.Frontier frontier(String id) throws IOException {
                    beforeRpc();
                    PreparedPublication.Frontier result = core.frontier(id);
                    if (staged[0] != null && !injected[0]) {
                        if (!first.id().equals(id) || !result.phase().equals("pending") || !staged[0].state().same(result.observed())
                                || !first.before().same(FileState.capture(first.target())) || !first.after().same(staged[0].state()) || appliedCalls[0] != 0) {
                            throw new AssertionError("Injection missed the last authorized pending frontier before rename");
                        }
                        Files.writeString(Path.of("/work/last-authorized-frontier.json"), JsonOutput.encode(Map.of(
                                "id", id, "phase", result.phase(), "observed", PreparedPublicationCodec.state(result.observed()), "applied_calls", 0)));
                        if (death) {
                            fixtureCommand("/usr/bin/kill", "-KILL", Long.toString(supervisor));
                            try {
                                while (ProcessHandle.of(supervisor).map(ProcessHandle::isAlive).orElse(false)) Thread.sleep(5);
                            } catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new IOException(e); }
                            killed[0] = true;
                        }
                        if (bind) {
                            boundPath[0] = mode.equals("publish-native-stage-bind") ? staged[0].path() : first.target().getParent();
                            fixtureCommand("/fixtures/mount-custody", "bind", boundPath[0].toString());
                        }
                        verifyInheritedPins(application);
                        if (!application.get("mount_namespace").equals(Files.readSymbolicLink(Path.of("/proc/self/ns/mnt")).toString())) {
                            throw new AssertionError("Late self-bind changed the namespace identity");
                        }
                        injected[0] = true;
                    }
                    return result;
                }
                public void before(String id, FileState state) throws IOException { beforeRpc(); core.before(id, state); }
                public PreparedPublication.Stage stage(PreparedPublication.Put put) throws IOException {
                    beforeRpc(); staged[0] = core.stage(put); return staged[0];
                }
                public void applied(String id, FileState state) throws IOException { appliedCalls[0]++; beforeRpc(); core.applied(id, state); }
            };
            boolean refused = false;
            try { plan.apply(wrapper); } catch (IOException expected) { refused = true; }
            if (!injected[0] || killed[0] != death || !refused) throw new AssertionError("Late publication boundary was not exercised");
            if (bind) {
                if (!localRefusal[0] || appliedCalls[0] != 0 || !first.before().same(FileState.capture(first.target()))
                        || !staged[0].state().same(FileState.capture(staged[0].path()))
                        || !plan.configuration().before().same(FileState.capture(plan.configuration().target()))) {
                    throw new AssertionError("Late mount refusal did not preserve the exact before/stage objects");
                }
                verifyInheritedPins(application);
                byte[] originalRefusal = Files.readAllBytes(Path.of("/work/native-mount-refused.json"));
                byte[] requests = Files.readAllBytes(Path.of("/work/publication-requests.jsonl"));
                fixtureCommand("/fixtures/mount-custody", "unmount");
                boolean sticky = false;
                try { core.verifyLive(); }
                catch (IOException expected) {
                    if (!"Publication live custody was invalidated".equals(expected.getMessage())) throw expected;
                    sticky = true;
                    Files.writeString(Path.of("/work/native-sticky-refused.json"), JsonOutput.encode(Map.of(
                            "reason", expected.getMessage(), "same_authority", true, "applied_calls", appliedCalls[0])));
                }
                if (!sticky || appliedCalls[0] != 0
                        || !Arrays.equals(requests, Files.readAllBytes(Path.of("/work/publication-requests.jsonl")))
                        || !Arrays.equals(originalRefusal, Files.readAllBytes(Path.of("/work/native-mount-refused.json")))) {
                    throw new AssertionError("Restoring the mount revived native authority or caused RPC/writes");
                }
                verifyInheritedPins(application);
                unchangedMountObjects();
            } else if (!first.after().same(FileState.capture(first.target())) || appliedCalls[0] != 1) {
                throw new AssertionError("Stable-namespace Core death did not retain the authorized rename");
            }
            if (death) {
                Files.writeString(Path.of("/work/publication-result"), "1\n");
                Files.writeString(Path.of("/work/after-core-death"), bind
                        ? "local mount guard refused rename after Core death" : "authorized rename completed; receipt unresolved");
            }
        }
    }
}
