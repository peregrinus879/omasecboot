import org.limine.entry.tool.processes.DirectoryBinding;
import org.limine.entry.tool.processes.FileState;
import org.limine.entry.tool.processes.JsonOutput;
import org.limine.entry.tool.processes.ManagedJson;
import org.limine.entry.tool.processes.PreparedPublication;
import org.limine.entry.tool.processes.PreparedPublicationCodec;
import org.limine.entry.tool.processes.ReadObservation;

import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Real executor/filesystem/restart tests. The fixture authority is not the Core protocol. */
public class PreparedPublicationContract {
    private static int count;
    private static final Path ROOT = Path.of("/work/publication");
    private static final Path FAULT = Path.of("/work/publication-sync-fault");
    private static final String OLD_RESOURCE = "previous boot resource\n";
    private static final String NEW_RESOURCE = "fixture final locally prepared bytes\n";
    private static final String OLD_CONFIG = "previous configuration\n";
    private static final String NEW_CONFIG = "literal prepared configuration\n";

    @FunctionalInterface interface Checked { void run() throws Exception; }
    private static void require(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private static void refusal(Checked check) throws Exception {
        boolean refused = false;
        try { check.run(); } catch (IOException | IllegalArgumentException expected) { refused = true; }
        require(refused, "unsafe operation was accepted");
    }
    private static void pass(String name) { System.out.println("PASS: prepared/" + name); count++; }

    private record Fixture(Path root, PreparedPublication plan) {
        Path boot() { return root.resolve("boot"); }
        Path resource() { return boot().resolve("resource"); }
        Path config() { return boot().resolve("limine.conf"); }
        Path ledger() { return root.resolve("ledger"); }
        void unchanged() throws IOException {
            require(Files.readString(resource()).equals(OLD_RESOURCE), "resource changed before refusal");
            require(Files.readString(config()).equals(OLD_CONFIG), "configuration changed before refusal");
            require(Files.exists(boot().resolve("retired/child")), "retirement happened before refusal");
        }
        void complete() throws IOException {
            require(Files.readString(resource()).equals(NEW_RESOURCE), "wrong resource bytes");
            require(Files.readString(config()).equals(NEW_CONFIG), "wrong literal configuration");
            require(!Files.exists(boot().resolve("retired")), "retirement incomplete");
            require(Files.readString(root.resolve("reference")).equals("referenced bytes"), "referenced resource changed");
        }
    }

    private static PreparedPublication.Put put(String id, Path target, Path retained) throws IOException {
        return new PreparedPublication.Put(id, target, FileState.capture(target), retained,
                FileState.capture(retained), DirectoryBinding.capture(target.getParent()));
    }
    private static Fixture fixture(String name) throws Exception {
        Path root = ROOT.resolve(name), boot = root.resolve("boot"), retained = root.resolve("retained");
        Files.createDirectories(boot.resolve("retired")); Files.createDirectories(retained); Files.createDirectories(root.resolve("ledger"));
        Files.writeString(boot.resolve("resource"), OLD_RESOURCE); Files.writeString(boot.resolve("limine.conf"), OLD_CONFIG);
        Files.writeString(boot.resolve("retired/child"), "retired resource");
        Files.writeString(root.resolve("reference"), "referenced bytes");
        Files.writeString(retained.resolve("resource"), NEW_RESOURCE); Files.writeString(retained.resolve("config"), NEW_CONFIG);
        PreparedPublication plan = new PreparedPublication("11111111-1111-4111-8111-111111111111",
                List.of(put("resource", boot.resolve("resource"), retained.resolve("resource"))),
                put("configuration", boot.resolve("limine.conf"), retained.resolve("config")),
                List.of(new PreparedPublication.Delete("directory", boot.resolve("retired"), FileState.capture(boot.resolve("retired")), DirectoryBinding.capture(boot)),
                        new PreparedPublication.Delete("child", boot.resolve("retired/child"), FileState.capture(boot.resolve("retired/child")), DirectoryBinding.capture(boot.resolve("retired")))),
                List.of(new PreparedPublication.Reference(root.resolve("reference"), new ReadObservation().file(root.resolve("reference")))));
        Files.write(root.resolve("plan.json"), PreparedPublicationCodec.encode(plan));
        return new Fixture(root, plan);
    }

    private static void durable(Path path, Map<String, Object> document) throws IOException {
        Files.writeString(path, JsonOutput.encode(document), StandardOpenOption.CREATE_NEW);
        try (FileChannel channel = FileChannel.open(path, StandardOpenOption.READ)) { channel.force(true); }
        try (FileChannel channel = FileChannel.open(path.getParent(), StandardOpenOption.READ)) { channel.force(true); }
    }

    private static class Journal implements PreparedPublication.Authority {
        final Fixture fixture;
        String failure = "";
        Journal(Fixture fixture) { this.fixture = fixture; }
        @Override public void validate(PreparedPublication plan) throws IOException {
            if (failure.equals("authority")) throw new IOException("fixture authority refusal");
            require(Arrays.equals(Files.readAllBytes(fixture.root.resolve("plan.json")), PreparedPublicationCodec.encode(plan)), "plan authority changed");
        }
        @Override public PreparedPublication.Frontier frontier(String effect) throws IOException {
            Path applied = fixture.ledger().resolve(effect + ".applied"), pending = fixture.ledger().resolve(effect + ".pending");
            if (Files.exists(applied)) {
                return new PreparedPublication.Frontier("applied", PreparedPublicationCodec.readState(ManagedJson.read(Files.readAllBytes(applied))));
            }
            FileState staged = null;
            try (var files = Files.list(fixture.ledger())) {
                Path latest = files.filter(path -> path.getFileName().toString().startsWith(effect + ".stage-"))
                        .sorted().reduce((first, second) -> second).orElse(null);
                if (latest != null) staged = PreparedPublicationCodec.readState(ManagedJson.read(Files.readAllBytes(latest)));
            }
            return new PreparedPublication.Frontier(Files.exists(pending) ? "pending" : "unstarted", staged);
        }
        @Override public void before(String effect, FileState observed) throws IOException {
            if (failure.equals("before-" + effect)) throw new IOException("fixture pending-record failure");
            Path path = fixture.ledger().resolve(effect + ".pending");
            if (!Files.exists(path)) durable(path, PreparedPublicationCodec.state(observed));
            if (effect.equals("configuration")) require(Files.readString(fixture.resource()).equals(NEW_RESOURCE), "configuration preceded resource");
            if (effect.equals("child")) require(Files.readString(fixture.config()).equals(NEW_CONFIG), "retirement preceded configuration");
            if (failure.equals("delete-race") && effect.equals("directory")) Files.writeString(fixture.boot().resolve("retired/new-data"), "unplanned");
        }
        @Override public PreparedPublication.Stage stage(PreparedPublication.Put put) throws IOException {
            if (failure.equals("stage")) throw new IOException("fixture staged-byte preparation failure");
            Path path = Files.createTempFile(put.target().getParent(), ".prepared-", ".stage");
            Files.copy(put.retained(), path, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.COPY_ATTRIBUTES);
            PreparedPublication.Stage stage = new PreparedPublication.Stage(path, FileState.capture(path));
            if (failure.equals("stage-drift")) Files.writeString(path, "corrupt stage");
            if (failure.equals("stage-link")) {
                Files.delete(path); Files.createSymbolicLink(path, put.retained());
                return new PreparedPublication.Stage(path, put.after());
            }
            if (failure.equals("stage-retained")) return new PreparedPublication.Stage(put.retained(), FileState.capture(put.retained()));
            if (failure.equals("stage-target-drift")) Files.writeString(put.target(), "third state");
            long count;
            try (var files = Files.list(fixture.ledger())) {
                count = files.filter(file -> file.getFileName().toString().startsWith(put.id() + ".stage-")).count();
            }
            durable(fixture.ledger().resolve(put.id() + ".stage-" + String.format("%06d", count)), PreparedPublicationCodec.state(stage.state()));
            return stage;
        }
        @Override public void applied(String effect, FileState state) throws IOException {
            if (failure.equals("crash-" + effect)) Runtime.getRuntime().halt(71);
            if (failure.equals("applied-" + effect)) throw new IOException("fixture applied-record failure");
            durable(fixture.ledger().resolve(effect + ".applied"), PreparedPublicationCodec.state(state));
        }
    }

    private static Fixture restore(Path root) throws IOException {
        return new Fixture(root, PreparedPublicationCodec.decode(Files.readAllBytes(root.resolve("plan.json"))));
    }
    private static void child(Fixture fixture, String failure, int expected) throws Exception {
        Process process = new ProcessBuilder("/jdk/bin/java", "-Xmx128m", "-XX:ActiveProcessorCount=2", "-XX:-UsePerfData",
                "-Duser.home=/work/home", "-cp", System.getProperty("java.class.path"), PreparedPublicationContract.class.getName(),
                "worker", fixture.root.toString(), failure).inheritIO().start();
        require(process.waitFor() == expected, "unexpected fresh worker terminal result");
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0) {
            Fixture fixture = restore(Path.of(args[1])); Journal journal = new Journal(fixture); journal.failure = args[2];
            fixture.plan.apply(journal); fixture.complete(); return;
        }
        Files.writeString(FAULT, "pass");
        Fixture normal = fixture("ordered");
        child(normal, "", 0); normal.complete();
        child(normal, "", 0); normal.complete(); pass("ordered-and-idempotent-fresh-worker");

        for (String effect : List.of("resource", "configuration", "child", "directory")) {
            Fixture fixture = fixture("crash-" + effect);
            child(fixture, "crash-" + effect, 71);
            require(Files.exists(fixture.ledger().resolve(effect + ".pending")) && !Files.exists(fixture.ledger().resolve(effect + ".applied")), "crash frontier was not retained");
            child(fixture, "", 0); fixture.complete(); pass("restart-after-" + effect);
        }
        for (String failure : List.of("authority", "before-resource", "stage", "stage-drift", "stage-link", "stage-retained")) {
            Fixture fixture = fixture(failure); Journal journal = new Journal(fixture); journal.failure = failure;
            refusal(() -> fixture.plan.apply(journal)); fixture.unchanged(); pass(failure);
        }
        for (String effect : List.of("resource", "configuration")) {
            Fixture fixture = fixture("record-" + effect); Journal journal = new Journal(fixture); journal.failure = "applied-" + effect;
            refusal(() -> fixture.plan.apply(journal)); child(fixture, "", 0); fixture.complete(); pass("receipt-failure-" + effect);
        }
        Fixture missing = fixture("retained-missing"); Files.delete(missing.plan.configuration().retained());
        refusal(() -> missing.plan.apply(new Journal(missing))); missing.unchanged(); pass("all-retained-inputs-before-first-write");
        Fixture changed = fixture("reference-drift"); Files.writeString(changed.root.resolve("reference"), "changed reference");
        refusal(() -> changed.plan.apply(new Journal(changed))); changed.unchanged(); pass("reference-drift");
        Fixture extra = fixture("extra-deletion"); Files.writeString(extra.boot().resolve("retired/unplanned"), "preserve");
        refusal(() -> extra.plan.apply(new Journal(extra))); extra.unchanged(); pass("finite-deletion-members");

        Fixture raced = fixture("delete-race"); Journal racedJournal = new Journal(raced); racedJournal.failure = "delete-race";
        refusal(() -> raced.plan.apply(racedJournal)); require(Files.readString(raced.boot().resolve("retired/new-data")).equals("unplanned"), "deleted unplanned data");
        pass("late-unplanned-deletion-member");
        Fixture stageRace = fixture("stage-target-drift"); Journal stageJournal = new Journal(stageRace); stageJournal.failure = "stage-target-drift";
        refusal(() -> stageRace.plan.apply(stageJournal)); require(Files.readString(stageRace.resource()).equals("third state"), "overwrote target race");
        pass("target-rechecked-after-stage");

        Fixture after = fixture("unstarted-after"); Files.copy(after.plan.puts().getFirst().retained(), after.resource(), StandardCopyOption.REPLACE_EXISTING);
        refusal(() -> after.plan.apply(new Journal(after))); require(Files.readString(after.config()).equals(OLD_CONFIG), "unrecorded after-state was authority");
        pass("after-bytes-without-pending-refused");
        Fixture third = fixture("pending-third"); child(third, "crash-resource", 71); Files.writeString(third.resource(), "third state");
        refusal(() -> third.plan.apply(new Journal(third))); require(Files.readString(third.resource()).equals("third state"), "third state overwritten");
        pass("pending-third-state-refused");
        Fixture applied = fixture("applied-inode"); child(applied, "", 0);
        Files.copy(applied.plan.puts().getFirst().retained(), applied.resource(), StandardCopyOption.REPLACE_EXISTING);
        refusal(() -> applied.plan.apply(new Journal(applied))); pass("applied-inode-replacement-refused");
        Fixture pending = fixture("pending-without-stage"); Journal pendingJournal = new Journal(pending); pendingJournal.failure = "stage";
        refusal(() -> pending.plan.apply(pendingJournal));
        Files.copy(pending.plan.puts().getFirst().retained(), pending.resource(), StandardCopyOption.REPLACE_EXISTING);
        refusal(() -> pending.plan.apply(new Journal(pending))); pass("pending-after-without-journaled-stage-refused");
        Fixture substituted = fixture("pending-inode"); child(substituted, "crash-resource", 71);
        Files.copy(substituted.plan.puts().getFirst().retained(), substituted.resource(), StandardCopyOption.REPLACE_EXISTING);
        refusal(() -> substituted.plan.apply(new Journal(substituted))); pass("pending-stage-inode-substitution-refused");
        Fixture readRace = fixture("retained-read-race"); Files.writeString(FAULT, "target-read");
        refusal(() -> readRace.plan.apply(new Journal(readRace))); Files.writeString(FAULT, "pass");
        require(Files.readString(readRace.resource()).equals("third state"), "retained-read race was not injected or was overwritten");
        require(Files.readString(readRace.config()).equals(OLD_CONFIG), "retained-read race published configuration");
        pass("operative-observation-rechecked-after-retained-read");
        Fixture permissions = fixture("permission-drift"); Files.setPosixFilePermissions(permissions.resource(), PosixFilePermissions.fromString("rw-r--r--"));
        refusal(() -> permissions.plan.apply(new Journal(permissions))); pass("before-metadata-drift");

        Fixture rebound = fixture("parent-rebind"); Path moved = rebound.root.resolve("original-boot"); Files.move(rebound.boot(), moved);
        Files.createSymbolicLink(rebound.boot(), moved);
        refusal(() -> rebound.plan.apply(new Journal(rebound))); rebound.unchanged(); pass("same-leaf-parent-rebind-refused");
        Fixture linked = fixture("parent-link"); Path real = linked.root.resolve("actual-boot"); Files.move(linked.boot(), real); Files.createSymbolicLink(linked.boot(), real);
        PreparedPublication.Put oldPut = linked.plan.puts().getFirst(), oldConfig = linked.plan.configuration();
        PreparedPublication linkPlan = new PreparedPublication(linked.plan.invocation(), List.of(put(oldPut.id(), oldPut.target(), oldPut.retained())),
                put(oldConfig.id(), oldConfig.target(), oldConfig.retained()), List.of(), linked.plan.references());
        Files.write(linked.root.resolve("plan.json"), PreparedPublicationCodec.encode(linkPlan));
        linkPlan.apply(new Journal(new Fixture(linked.root, linkPlan))); pass("recorded-parent-link-supported");

        Fixture alias = fixture("aliased-config-delete"); Path aliasPath = alias.root.resolve("alias"); Files.createSymbolicLink(aliasPath, alias.boot());
        Path aliasConfig = aliasPath.resolve("limine.conf");
        Files.writeString(alias.plan.configuration().retained(), OLD_CONFIG);
        PreparedPublication aliasPlan = new PreparedPublication(alias.plan.invocation(), List.of(),
                put("configuration", alias.config(), alias.plan.configuration().retained()),
                List.of(new PreparedPublication.Delete("alias-delete", aliasConfig, FileState.capture(aliasConfig), DirectoryBinding.capture(aliasPath))), List.of());
        Files.write(alias.root.resolve("plan.json"), PreparedPublicationCodec.encode(aliasPlan));
        refusal(() -> aliasPlan.apply(new Journal(new Fixture(alias.root, aliasPlan)))); alias.unchanged(); pass("aliased-config-delete-refused");
        Fixture inputAlias = fixture("aliased-retained"); Path inputAliasPath = inputAlias.root.resolve("alias"); Files.createSymbolicLink(inputAliasPath, inputAlias.boot());
        PreparedPublication inputPlan = new PreparedPublication(inputAlias.plan.invocation(), List.of(),
                put("configuration", inputAlias.config(), inputAliasPath.resolve("limine.conf")), List.of(), List.of());
        Files.write(inputAlias.root.resolve("plan.json"), PreparedPublicationCodec.encode(inputPlan));
        refusal(() -> inputPlan.apply(new Journal(new Fixture(inputAlias.root, inputPlan)))); inputAlias.unchanged(); pass("aliased-retained-input-refused");
        Fixture referenceAlias = fixture("aliased-reference"); Path refLink = referenceAlias.root.resolve("link"); Files.createSymbolicLink(refLink, referenceAlias.boot().resolve("retired/child"));
        PreparedPublication referencePlan = new PreparedPublication(referenceAlias.plan.invocation(), referenceAlias.plan.puts(), referenceAlias.plan.configuration(),
                referenceAlias.plan.deletes(), List.of(new PreparedPublication.Reference(refLink, new ReadObservation().file(refLink))));
        Files.write(referenceAlias.root.resolve("plan.json"), PreparedPublicationCodec.encode(referencePlan));
        refusal(() -> referencePlan.apply(new Journal(new Fixture(referenceAlias.root, referencePlan)))); referenceAlias.unchanged(); pass("aliased-reference-input-refused");
        Fixture finalDrift = fixture("final-resource-drift"); Journal finalJournal = new Journal(finalDrift) {
            @Override public void applied(String effect, FileState state) throws IOException {
                super.applied(effect, state); if (effect.equals("directory")) Files.writeString(fixture.resource(), "late third state");
            }
        };
        refusal(() -> finalDrift.plan.apply(finalJournal)); pass("final-effect-set-rechecked");
        Fixture bridge = fixture("intermediate-link"); Path bridgeLink = bridge.root.resolve("bridge"), viewLink = bridge.root.resolve("view");
        Files.createSymbolicLink(bridgeLink, Path.of("boot")); Files.createSymbolicLink(viewLink, Path.of("bridge"));
        PreparedPublication bridgePlan = new PreparedPublication(bridge.plan.invocation(), List.of(),
                put("configuration", viewLink.resolve("limine.conf"), bridge.plan.configuration().retained()),
                List.of(new PreparedPublication.Delete("bridge", bridgeLink, FileState.capture(bridgeLink), DirectoryBinding.capture(bridge.root))), List.of());
        Files.write(bridge.root.resolve("plan.json"), PreparedPublicationCodec.encode(bridgePlan));
        refusal(() -> bridgePlan.apply(new Journal(new Fixture(bridge.root, bridgePlan)))); bridge.unchanged();
        require(Files.isSymbolicLink(bridgeLink), "removed intermediate resolution link"); pass("intermediate-symlink-deletion-refused-before-publication");
        Fixture reboundBridge = fixture("intermediate-link-rebind"); Path reboundLink = reboundBridge.root.resolve("bridge"), reboundView = reboundBridge.root.resolve("view");
        Files.createSymbolicLink(reboundLink, Path.of("boot")); Files.createSymbolicLink(reboundView, Path.of("bridge"));
        PreparedPublication reboundPlan = new PreparedPublication(reboundBridge.plan.invocation(), List.of(),
                put("configuration", reboundView.resolve("limine.conf"), reboundBridge.plan.configuration().retained()), List.of(), List.of());
        Files.write(reboundBridge.root.resolve("plan.json"), PreparedPublicationCodec.encode(reboundPlan));
        Files.delete(reboundLink); Files.createSymbolicLink(reboundLink, Path.of("./boot"));
        refusal(() -> reboundPlan.apply(new Journal(new Fixture(reboundBridge.root, reboundPlan)))); reboundBridge.unchanged();
        pass("same-destination-intermediate-link-rebind-refused");
        Fixture fileLinks = fixture("file-link-chain"); Path fileBridge = fileLinks.root.resolve("bridge"), fileView = fileLinks.root.resolve("view");
        Files.createSymbolicLink(fileBridge, Path.of("reference")); Files.createSymbolicLink(fileView, Path.of("bridge"));
        PreparedPublication filePlan = new PreparedPublication(fileLinks.plan.invocation(), fileLinks.plan.puts(), fileLinks.plan.configuration(),
                List.of(new PreparedPublication.Delete("bridge", fileBridge, FileState.capture(fileBridge), DirectoryBinding.capture(fileLinks.root))),
                List.of(new PreparedPublication.Reference(fileView, new ReadObservation().file(fileView))));
        Files.write(fileLinks.root.resolve("plan.json"), PreparedPublicationCodec.encode(filePlan));
        refusal(() -> filePlan.apply(new Journal(new Fixture(fileLinks.root, filePlan)))); fileLinks.unchanged();
        require(Files.isSymbolicLink(fileBridge), "removed a file-reference link dependency"); pass("intermediate-file-reference-link-deletion-refused");

        for (String fault : List.of("stage", "target", "directory")) {
            Fixture fixture = fixture("sync-" + fault); Files.writeString(FAULT, fault);
            refusal(() -> fixture.plan.apply(new Journal(fixture))); Files.writeString(FAULT, "pass");
            require(!Files.exists(fixture.ledger().resolve("resource.applied")), "failed sync got an applied receipt");
            if (fault.equals("stage")) fixture.unchanged();
            child(fixture, "", 0); fixture.complete(); pass("real-" + fault + "-sync-failure-replay");
        }
        Fixture deletionSync = fixture("sync-deletion"); Journal deletionJournal = new Journal(deletionSync) {
            @Override public void before(String effect, FileState state) throws IOException {
                super.before(effect, state); if (effect.equals("child")) Files.writeString(FAULT, "directory");
            }
        };
        refusal(() -> deletionSync.plan.apply(deletionJournal)); Files.writeString(FAULT, "pass");
        require(!Files.exists(deletionSync.ledger().resolve("child.applied")), "failed deletion sync got an applied receipt");
        child(deletionSync, "", 0); deletionSync.complete(); pass("real-deletion-sync-failure-replay");
        Fixture renameCrash = fixture("rename-crash"); Files.writeString(FAULT, "crash-directory");
        child(renameCrash, "", 72); Files.writeString(FAULT, "pass");
        require(!Files.exists(renameCrash.ledger().resolve("resource.applied")), "crashed rename was recorded applied");
        child(renameCrash, "", 0); renameCrash.complete(); pass("process-crash-after-rename-before-directory-sync");

        byte[] encoded = PreparedPublicationCodec.encode(normal.plan);
        require(Arrays.equals(encoded, PreparedPublicationCodec.encode(PreparedPublicationCodec.decode(encoded))), "codec changed exact plan");
        for (String bad : List.of(new String(encoded, StandardCharsets.UTF_8).replace("\"schema\":1", "\"schema\":2"),
                new String(encoded, StandardCharsets.UTF_8).replace("\"schema\":1", "\"schema\":1,\"extra\":true"),
                new String(encoded, StandardCharsets.UTF_8).replace("\"mode\":", "\"surplus\":true,\"mode\":"),
                new String(encoded, StandardCharsets.UTF_8).replace("\"uid\":0", "\"uid\":-1"))) {
            refusal(() -> PreparedPublicationCodec.decode(bad.getBytes(StandardCharsets.UTF_8)));
        }
        pass("exact-versioned-codec-and-unknown-fields");
        Map<String, Object> observation = new HashMap<>(new ReadObservation().file(normal.root.resolve("reference")));
        Map<String, String> identity = new HashMap<>(); identity.put("dev", "untrusted"); observation.put("identity", identity);
        PreparedPublication.Reference reference = new PreparedPublication.Reference(normal.root.resolve("reference"), observation);
        identity.put("dev", "changed"); require(!((Map<?, ?>) reference.observation().get("identity")).get("dev").equals("changed"), "reference aliases caller data");
        boolean immutable = false;
        try { reference.observation().put("sha256", "changed"); } catch (UnsupportedOperationException expected) { immutable = true; }
        require(immutable, "reference accessor is mutable"); pass("deeply-immutable-plan-data");
        System.out.println("Passed " + count + " prepared-publication contracts.");
    }
}
