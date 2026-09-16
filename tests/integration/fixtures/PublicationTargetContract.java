import org.limine.entry.tool.processes.DirectoryBinding;
import org.limine.entry.tool.processes.FileState;
import org.limine.entry.tool.processes.JsonOutput;
import org.limine.entry.tool.processes.PreparedPublication;
import org.limine.entry.tool.processes.PublicationTargets;
import org.limine.entry.tool.processes.ReadObservation;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/** Actual argv-first Main queries against the bound composed producer in /work.
 * The runner supplies real directory/file bind aliases and a FIFO in the fixture
 * filesystem. These are namespace tests, not mounted-FAT or Core mkdir/journal
 * acceptance. Pure FAT name classification is labeled separately and never used
 * to emulate filesystem lookup. PreparedPublicationContract remains the executor,
 * symlink/reference/deletion and replay suite.
 */
public class PublicationTargetContract {
    private static final Path ESP = Path.of("/work/tree/esp");
    private static final Path EVIDENCE = Path.of("/work/evidence");
    private static final String ATTRIBUTES = "unix:dev,ino,mode,uid,gid,size,lastModifiedTime,ctime";
    private static int cliCount, genericCount, pureCount;

    public static void main(String[] args) throws Exception {
        require(args.length == 0 && Path.of("").toAbsolutePath().equals(Path.of("/work")), "Requires the disposable /work namespace");
        require(Files.isSameFile(ESP.resolve("physical"), ESP.resolve("view")), "Runner did not supply the directory bind alias");
        require(Files.isSameFile(ESP.resolve("bound-file"), ESP.resolve("bound-file-view")), "Runner did not supply the file bind alias");
        require(!Files.getFileStore(ESP).type().equals("vfat"), "These fixture expectations require the non-FAT namespace");
        Files.writeString(ESP.resolve("limine.conf"), "fixture configuration\n");

        cli("stock-linux-before-mkdir", intent("machine/linux/initramfs.img", "machine/linux/vmlinuz"), null);
        Map<String, Object> uki = intent("EFI/Linux/omarchy_linux.efi");
        uki.put("operation", "add-uki"); resource(uki, 0).put("role", "uki");
        cli("stock-uki-before-mkdir", uki, null);
        cli("duplicate-targets-before-mkdir", intent("missing/x", "missing/x"), "Duplicate target");
        cli("target-as-ancestor-before-mkdir", intent("missing/x", "missing/x/child"), "Overlapping or aliased publication targets");
        cli("configuration-duplicate", intent("limine.conf"), "Duplicate target");
        cli("configuration-as-ancestor", intent("limine.conf/child"), "non-directory publication ancestor");
        cli("noncanonical-escape", intent("../escape"), "Noncanonical target-validation path");
        Map<String, Object> outside = intent("outside");
        resource(outside, 0).put("target", "/work/tree/esp-sibling/escape");
        cli("canonical-outside-esp", outside, "outside the admitted ESP");
        cli("exact-argv", encode(intent("missing/x")), "Unexpected target validator operands", "extra");
        cli("trailing-document", encodeText(JsonOutput.encode(intent("missing/x")) + " {}"), "trailing document");
        cli("duplicate-json-key", encodeText("{\"operation\":\"add-uki\",\"operation\":\"add-kernel\"}"), "Invalid managed JSON document");
        cli("byte-limit", encodeText(" ".repeat(2 * 1024 * 1024 + 1)), "exceeds its byte limit");
        cli("invalid-utf8", new byte[]{'{', '"', 'x', '"', ':', '"', (byte) 0xff, '"', '}'}, "not UTF-8");
        cli("unpaired-surrogate", encodeText("{\"operation\":\"\\ud800\"}"), "Unpaired Unicode surrogate");
        Map<String, Object> extra = intent("missing/x"); extra.put("extra", true);
        cli("extra-intent-field", extra, "Unexpected target-validation fields");
        extra = intent("missing/x"); resource(extra, 0).put("extra", true);
        cli("extra-resource-field", extra, "Unexpected target-validation fields");
        extra = intent("missing/x"); resource(extra, 0).put("sha256", "bad");
        cli("bad-digest-shape", extra, "Invalid target-validation digest");
        extra = intent("missing/x"); resource(extra, 0).put("id", "configuration");
        cli("reserved-configuration-id", extra, "Invalid target-validation resource");
        extra = intent("missing/x", "missing/y"); resource(extra, 1).put("id", "resource-0");
        cli("duplicate-resource-id", extra, "Invalid target-validation resource");
        extra = intent("missing/x"); extra.put("resources", List.of());
        cli("empty-resource-set", extra, "Invalid target-validation resource set");
        extra = intent("missing/x"); extra.put("resources", Collections.nCopies(4097, 0));
        cli("resource-count-limit", extra, "Invalid target-validation resource set");
        extra = intent("missing/x"); extra.put("operation", "remove-kernel");
        cli("unsupported-operation", extra, "Unsupported target-validation operation");
        extra = intent("missing/x"); extra.put("publication", Map.of("kind", "deletion", "model", "producer-owned"));
        cli("unsupported-publication", extra, "Unsupported target-validation publication");
        extra = intent("missing/x"); extra.put("esp_path", "/work/tree/not-an-admitted-esp");
        cli("missing-esp", extra, "Missing or non-directory publication ancestor");

        // Only the fixture creates directories, one at a time between queries.
        // Each query must leave the then-current tree and all canaries unchanged.
        Map<String, Object> linux = intent("machine/linux/initramfs.img", "machine/linux/vmlinuz");
        Files.createDirectory(ESP.resolve("machine"));
        cli("linux-after-first-mkdir", linux, null);
        Files.createDirectory(ESP.resolve("machine/linux"));
        cli("linux-after-second-mkdir", linux, null);
        Files.writeString(ESP.resolve("machine/linux/vmlinuz"), "old payload\n");
        cli("existing-file-target", linux, null);
        Files.createDirectory(ESP.resolve("EFI"));
        cli("uki-after-first-mkdir", uki, null);
        Files.createDirectory(ESP.resolve("EFI/Linux"));
        cli("uki-after-second-mkdir", uki, null);
        Files.createDirectory(ESP.resolve("directory-target"));
        cli("directory-target", intent("directory-target"), "not a regular file");
        Files.writeString(ESP.resolve("file-parent"), "not a directory\n");
        cli("file-as-ancestor", intent("file-parent/child"), "non-directory publication ancestor");
        Files.createSymbolicLink(ESP.resolve("parent-link"), Path.of("machine"));
        cli("symlink-parent", intent("parent-link/child"), "non-directory publication ancestor");
        Files.createSymbolicLink(ESP.resolve("leaf-link"), Path.of("machine/linux/vmlinuz"));
        cli("symlink-target", intent("leaf-link"), "not a regular file");
        Files.createSymbolicLink(ESP.resolve("dangling"), Path.of("absent"));
        cli("dangling-parent", intent("dangling/child"), "non-directory publication ancestor");
        cli("fifo-target", intent("fifo"), "not a regular file");
        cli("case-sensitive-distinct-names", intent("case/File", "case/file"), null);
        cli("case-sensitive-trailing-dots", intent("dots/file", "dots/file."), null);
        cli("unicode-source-basename-freedom", intent("unicode/été.img", "unicode/vmlinuz"), null);

        // Physical parents, rather than their lexical prefixes, determine overlap.
        cli("bind-parent-absent-leaf-alias", intent("physical/resource", "view/resource"), "Overlapping or aliased publication targets");
        Map<String, Object> aliased = intent("physical/new/item", "view/new/item");
        cli("bind-parent-missing-descendant-alias", aliased, "Overlapping or aliased publication targets");
        cli("bind-parent-target-as-ancestor", intent("physical/branch", "view/branch/child"), "Overlapping or aliased publication targets");
        cli("bind-parent-distinct-targets-before-mkdir", intent("physical/new/a", "view/new/b"), null);
        Files.createDirectory(ESP.resolve("physical/new"));
        cli("bind-parent-alias-after-mkdir", aliased, "Overlapping or aliased publication targets");
        cli("bind-parent-distinct-targets-after-mkdir", intent("physical/new/a", "view/new/b"), null);
        Files.writeString(ESP.resolve("physical/resource"), "old aliased payload\n");
        cli("bind-parent-present-leaf-alias", intent("physical/resource", "view/resource"), "Overlapping or aliased publication targets");
        Files.writeString(ESP.resolve("physical/config"), "aliased configuration\n");
        Map<String, Object> aliasedConfig = intent("view/config");
        aliasedConfig.put("configuration", configuration(ESP.resolve("physical/config")));
        cli("bind-parent-configuration-alias", aliasedConfig, "Overlapping or aliased publication targets");
        Path hardlink = Files.writeString(ESP.resolve("hardlink-a"), "separate directory entries\n");
        Files.createLink(ESP.resolve("hardlink-b"), hardlink);
        require(Files.isSameFile(hardlink, ESP.resolve("hardlink-b")), "Hardlink fixture lost shared identity");
        cli("separate-hardlink-targets", intent("hardlink-a", "hardlink-b"), null);
        Files.createLink(ESP.resolve("configuration-hardlink"), ESP.resolve("limine.conf"));
        cli("separate-configuration-hardlink", intent("configuration-hardlink"), null);
        cli("separate-file-bind-entries", intent("bound-file", "bound-file-view"), null);

        genericNamespaces();
        pureFatNames();
        System.out.println("Passed " + cliCount + " read-only target-validator CLI contracts, " + genericCount
                + " generic namespace checks and " + pureCount + " pure FAT name classifications.");
    }

    private static Map<String, Object> intent(String... targets) throws IOException {
        List<Map<String, Object>> resources = new ArrayList<>();
        for (int i = 0; i < targets.length; i++) {
            resources.add(new LinkedHashMap<>(Map.of("id", "resource-" + i, "role", i == 0 ? "initramfs" : "kernel",
                    "source", "/work/tree/unread-source-" + i, "target", ESP.resolve(targets[i]).toString(), "sha256", "0".repeat(64))));
        }
        // Namespace validation consumes the already validated intent. Source byte
        // proof and the opaque rendering model belong to the existing owners;
        // these absent source paths must neither be read nor initialized here.
        return new LinkedHashMap<>(Map.of("operation", "add-kernel", "esp_path", ESP.toString(),
                "configuration", configuration(ESP.resolve("limine.conf")), "resources", resources,
                "publication", Map.of("kind", "addition", "model", "producer-owned-model")));
    }
    private static Map<String, Object> configuration(Path path) throws IOException {
        return Map.of("path", path.toString(), "sha256", FileState.hash(path));
    }
    @SuppressWarnings("unchecked")
    private static Map<String, Object> resource(Map<String, Object> intent, int index) {
        return ((List<Map<String, Object>>) intent.get("resources")).get(index);
    }
    private static byte[] encode(Map<String, Object> intent) { return encodeText(JsonOutput.encode(intent)); }
    private static byte[] encodeText(String text) { return text.getBytes(StandardCharsets.UTF_8); }

    private static void cli(String name, Map<String, Object> intent, String refusal) throws Exception {
        cli(name, encode(intent), refusal);
    }
    private static void cli(String name, byte[] input, String refusal, String... operands) throws Exception {
        Path evidence = Files.createDirectory(EVIDENCE.resolve(name));
        Files.write(evidence.resolve("stdin"), input);
        List<String> command = new ArrayList<>(List.of("/jdk/bin/java", "-Xmx128m", "-XX:ActiveProcessorCount=2", "-XX:-UsePerfData",
                "-Duser.home=/work/home", "-Djava.io.tmpdir=/tmp", "-cp", System.getProperty("java.class.path"),
                "org.limine.entry.tool.Main", "--validate-managed-targets"));
        command.addAll(List.of(operands));
        Map<Path, Map<String, Object>> before = snapshot();
        Process process = new ProcessBuilder(command).redirectInput(evidence.resolve("stdin").toFile())
                .redirectOutput(evidence.resolve("stdout").toFile()).redirectError(evidence.resolve("stderr").toFile()).start();
        try {
            require(process.waitFor(20, TimeUnit.SECONDS), name + ": validator timed out");
            int status = process.exitValue();
            Files.writeString(evidence.resolve("exit-status"), status + "\n");
            require(snapshot().equals(before), name + ": validator changed the fixture namespace, bytes or metadata");
            String stderr = Files.readString(evidence.resolve("stderr"));
            require(Files.size(evidence.resolve("stdout")) == 0, name + ": validator wrote stdout");
            require(status == (refusal == null ? 0 : 1), name + ": unexpected exit " + status + ": " + stderr);
            require(refusal == null ? stderr.isEmpty() : stderr.contains(refusal), name + ": unexpected diagnostic: " + stderr);
        } finally {
            if (process.isAlive()) {
                process.descendants().forEach(ProcessHandle::destroyForcibly);
                process.destroyForcibly();
                require(process.waitFor(5, TimeUnit.SECONDS), "Could not stop timed-out validator");
            }
        }
        cliCount++;
        System.out.println("PASS: publication-target/cli/" + name);
    }

    /** Byte/identity/metadata and entry-set comparison with no link following.
     * Exclude only harness output/evidence; access-time updates are ordinary reads.
     * Observe writable initialization locations as well as output/source paths.
     */
    private static Map<Path, Map<String, Object>> snapshot() throws IOException {
        Map<Path, Map<String, Object>> result = new LinkedHashMap<>();
        for (String root : List.of("/work", "/etc", "/var", "/run", "/sys", "/tmp", "/usr/share/limine-entry-tool.d")) {
            try (var paths = Files.walk(Path.of(root))) {
                for (Path path : paths.filter(path -> !path.startsWith(EVIDENCE)
                        && !path.equals(Path.of("/work/stdout")) && !path.equals(Path.of("/work/stderr"))).toList()) {
                    Map<String, Object> state = new LinkedHashMap<>(Files.readAttributes(path, ATTRIBUTES, LinkOption.NOFOLLOW_LINKS));
                    int kind = ((Number) state.get("mode")).intValue() & 0170000;
                    if (kind == 0100000) state.put("sha256", FileState.hash(path));
                    if (kind == 0120000) state.put("link", Files.readSymbolicLink(path).toString());
                    result.put(path, state);
                }
            }
        }
        return result;
    }

    private static PreparedPublication.Put put(String id, Path target, Path retained) throws IOException {
        return new PreparedPublication.Put(id, target, FileState.capture(target), retained, FileState.capture(retained),
                DirectoryBinding.capture(target.getParent()));
    }
    private static void generic(String name, PreparedPublication plan, String refusal) throws IOException {
        Map<Path, Map<String, Object>> before = snapshot();
        try {
            plan.validateInitial();
            require(refusal == null, name + ": expected generic namespace refusal");
        } catch (IOException error) {
            require(refusal != null && error.getMessage().contains(refusal), name + ": unexpected refusal: " + error);
        }
        require(snapshot().equals(before), name + ": generic validator changed the fixture");
        genericCount++;
        System.out.println("PASS: publication-target/generic/" + name);
    }
    private static void genericNamespaces() throws IOException {
        Path retained = Files.createDirectory(Path.of("/work/tree/retained"));
        Path resource = Files.writeString(retained.resolve("resource"), "new prepared bytes\n");
        Path config = Files.writeString(retained.resolve("config"), "new configuration\n");
        PreparedPublication.Put configuration = put("configuration", ESP.resolve("limine.conf"), config);
        generic("separate-hardlink-targets", new PreparedPublication("hardlinks",
                List.of(put("a", ESP.resolve("hardlink-a"), resource), put("b", ESP.resolve("hardlink-b"), resource)),
                configuration, List.of(), List.of()), null);
        generic("separate-hardlink-reference", new PreparedPublication("hardlink-reference",
                List.of(put("a", ESP.resolve("hardlink-a"), resource)), configuration, List.of(),
                List.of(new PreparedPublication.Reference(ESP.resolve("hardlink-b"), new ReadObservation().file(ESP.resolve("hardlink-b"))))), null);
        generic("separate-file-bind-entries", new PreparedPublication("file-binds",
                List.of(put("a", ESP.resolve("bound-file"), resource), put("b", ESP.resolve("bound-file-view"), resource)),
                configuration, List.of(), List.of()), null);
        generic("aliased-parent-targets", new PreparedPublication("parent-alias",
                List.of(put("a", ESP.resolve("physical/resource"), resource), put("b", ESP.resolve("view/resource"), resource)),
                configuration, List.of(), List.of()), "Aliased publication targets");
    }

    private static void pureFatNames() throws Exception {
        // Reflection reaches only the pure string classifier. No filesystem is
        // labeled FAT and no synthetic result substitutes for actual lookup.
        var method = PublicationTargets.class.getDeclaredMethod("unresolvedNames", String.class, String.class, String.class);
        method.setAccessible(true);
        for (String[] row : List.of(new String[]{"initramfs", "initramfs...", "SAME"},
                new String[]{"VMLINUX", "vmlinux", "UNKNOWN"}, new String[]{"Ä", "ä", "UNKNOWN"},
                new String[]{"İ", "i", "DISTINCT"}, new String[]{"initramfs", "vmlinuz", "DISTINCT"},
                new String[]{"LONGDI~1", "LongDirectory", "DISTINCT"})) {
            require(method.invoke(null, row[0], row[1], "vfat").toString().equals(row[2]), "Unexpected pure FAT name classification");
            pureCount++;
        }
        // DISTINCT above does not predict a future shortname allocation. The
        // long-directory/8.3 case specifically records that prediction boundary.
        System.out.println("PASS: publication-target/pure-fat-name-classification (no mounted-FAT evidence)");
    }
    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
