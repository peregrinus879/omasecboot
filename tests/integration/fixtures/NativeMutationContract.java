import org.limine.entry.tool.formats.limine8.LimineEntry;
import org.limine.entry.tool.objects.Config;
import org.limine.entry.tool.objects.EntryOptions;
import org.limine.entry.tool.objects.TreeNode;
import org.limine.entry.tool.processes.LimineManager;
import org.limine.entry.tool.processes.LimineReader;
import org.limine.entry.tool.processes.LimineWriter;
import org.limine.entry.tool.processes.NativeMutations;
import org.limine.entry.tool.processes.NativeMutations.DeletionKind;
import org.limine.entry.tool.processes.NativeMutations.DeletionRequest;
import org.limine.entry.tool.processes.NativeMutations.ResolvedEfiLocation;
import org.limine.entry.tool.processes.NativeMutations.Result;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Actual producer classes with explicit expected selections and serialization.
 * Run in a disposable namespace with writable /work and an empty /sys. First
 * run "prepare", then expose /work/native-mutation-mounts at /proc/mounts and
 * prepend /work/bin to PATH for the default run. limine-native.sh compiles this
 * fixture with the actual composed producer and supplies real rm for ordinary
 * directory removal, plus the suite's sync/hash helpers in their pass modes.
 * With Bubblewrap, mount procfs
 * at /real-proc, create /proc, and link /proc/self to /real-proc/self; this keeps
 * JVM process observations available beside the fixture mount table without
 * binding over procfs's per-process mounts symlink. The mount table and findmnt
 * answers are fixtures, not FAT or firmware acceptance. No Core authority is
 * supplied here. Every input, output, and deletion target is under /work.
 */
public class NativeMutationContract {
    private static final String MACHINE = "11111111111111111111111111111111";
    private static final String UUID = "12345678-1234-1234-1234-123456789abc";
    private static final Config CONFIG = new Config(MACHINE, "Fixture Linux", "/work/esp", "uuid(other):");
    private static int passed;

    public static void main(String[] args) throws Exception {
        if (!Path.of("").toAbsolutePath().equals(Path.of("/work"))) {
            throw new IllegalStateException("Requires a disposable /work fixture context");
        }
        Config.QUIET = true;
        Config.ENABLE_COLOR = false;
        Config.ENABLE_UNICODE = false;
        Config.ENABLE_VERIFICATION = false;
        Config.ENABLE_OS_GENERATION = false;
        Config.ENABLE_SORT = false;
        Config.UKI_FILE_PREFIX = "contract";
        if (args.length == 1 && args[0].equals("prepare")) {
            prepare();
            return;
        }
        if (args.length != 0) throw new IllegalArgumentException("Only prepare or no arguments are supported");
        run("regular path selection and shared normal/fallback directory", NativeMutationContract::regularSelection);
        run("UKI protocol/path selection, all direct matches", NativeMutationContract::ukiSelection);
        run("UKI native prefix and suffix layout", NativeMutationContract::ukiLayout);
        run("keep-files exact ID and empty-ID name fallback", NativeMutationContract::keepFilesSelection);
        run("empty kernel operands and accumulated wrapper update", NativeMutationContract::emptyOperands);
        run("pure file-only and directory-only requests", NativeMutationContract::pureDeletionRequests);
        run("ordinary kernel deletion utility behavior", NativeMutationContract::ordinaryKernelDeletion);
        run("slash-path Nth occurrence across parents", NativeMutationContract::nthEntry);
        run("slash-path all for zero and negative index", NativeMutationContract::allEntries);
        run("slash-path blank segments", NativeMutationContract::blankSegments);
        run("machine-ID depth, first match, and exact identity", NativeMutationContract::machineDepth);
        run("machine-ID nonpositive depth selects root", NativeMutationContract::machineRoot);
        run("clear-node parsed serialization", NativeMutationContract::clearSerialization);
        run("EFI overwrite first compatible name preserves node state", NativeMutationContract::efiOverwrite);
        run("EFI insertion priority and top-level selection", NativeMutationContract::efiInsertion);
        run("EFI no-overwrite requires resolved input", NativeMutationContract::efiNoOverwrite);
        run("null EFI path selector is a non-match", NativeMutationContract::nullEfiSelector);
        run("EFI path/protocol predicates and all direct matches", NativeMutationContract::efiSelection);
        run("EFI boot and UUID selectors independently nullable", NativeMutationContract::efiNullableSelectors);
        run("EFI absent file, keep-files, and file-only removal", NativeMutationContract::efiDeletionRequests);
        run("ordinary EFI observation/deletion wrappers", NativeMutationContract::ordinaryEfi);
        run("immutable result requests", NativeMutationContract::immutableResults);
        run("ordinary kernel and UKI addition regression", NativeMutationContract::additionRegression);
        System.out.println("Passed " + passed + " native mutation contracts.");
    }

    private static void prepare() throws IOException {
        Files.createDirectories(Path.of("/work/esp/EFI/Linux"));
        Files.createDirectories(Path.of("/work/external/EFI"));
        Files.createDirectories(Path.of("/work/bin"));
        Files.writeString(Path.of("/work/hash-mode"), "pass\n");
        Files.writeString(Path.of("/work/sync-mode"), "pass\n");
        Files.writeString(Path.of("/work/native-mutation-mounts"),
                "fixture /work/esp vfat rw 0 0\nfixture /work/external iso9660 ro 0 0\n");
        Path findmnt = Path.of("/work/bin/findmnt");
        Files.writeString(findmnt, "#!/bin/bash\nset -euo pipefail\n"
                + "[[ $# == 4 && $1 == -no && $2 == PARTUUID && $3 == --mountpoint && $4 == /work/external ]] || exit 91\n"
                + "printf '%s\\n' '" + UUID + "'\n");
        Files.setPosixFilePermissions(findmnt, PosixFilePermissions.fromString("rwx------"));
    }

    private static void regularSelection() {
        TreeNode os = root();
        TreeNode normal = child(os, "//renamed", "comment: kernel-id=unrelated", "protocol: linux",
                "path: boot():/" + MACHINE + "/linux/vmlinuz#abc");
        TreeNode fallback = child(os, "//fallback", "protocol: linux",
                "kernel_path: boot():/" + MACHINE + "/LINUX/vmlinuz-fallback");
        TreeNode suffix = child(os, "//custom suffix", "protocol: linux",
                "path: boot():/" + MACHINE + "/linux/deeper/kernel");
        TreeNode lts = child(os, "//linux-lts", "protocol: linux", "path: boot():/" + MACHINE + "/linux-lts/vmlinuz");
        TreeNode efi = child(os, "//efi", "protocol: efi", "path: boot():/" + MACHINE + "/linux/vmlinuz");
        TreeNode foreign = child(os, "//foreign", "protocol: linux", "path: uuid(other):/" + MACHINE + "/linux/vmlinuz");
        TreeNode module = child(os, "//module", "protocol: linux", "module_path: boot():/" + MACHINE + "/linux/initramfs");
        TreeNode sameID = child(os, "//ID alone", "comment: kernel-id=linux", "protocol: linux", "path: boot():/elsewhere/vmlinuz");
        TreeNode directoryOnly = child(os, "//directory itself", "protocol: linux", "path: boot():/" + MACHINE + "/linux");
        TreeNode container = child(os, "//container");
        TreeNode nested = child(container, "///nested", "protocol: linux", "path: boot():/" + MACHINE + "/linux/vmlinuz");
        Result result = NativeMutations.removeKernel(os, CONFIG, "contract", "linux", false);
        equal(result, new Result(true, List.of(new DeletionRequest(DeletionKind.DIRECTORY, "/work/esp/" + MACHINE + "/linux"))));
        equal(os.getNodes(), List.of(lts, efi, foreign, module, sameID, directoryOnly, container));
        equal(container.getNodes(), List.of(nested));
        // Removal detaches matching children; it does not clear the detached objects.
        equal(List.of(normal.getCleanName(), fallback.getCleanName(), suffix.getCleanName()), List.of("renamed", "fallback", "custom suffix"));
    }

    private static void ukiSelection() {
        TreeNode os = root();
        child(os, "//not the kernel name", "protocol: efi", "path: boot():/EFI/Linux/contract_linux.efi#abc");
        child(os, "//uefi", "protocol: uefi", "image_path: boot():EFI/LINUX/CONTRACT_LINUX.EFI/");
        child(os, "//chainload", "protocol: efi_chainload", "path: boot():/EFI/Linux/contract_linux.efi");
        TreeNode linux = child(os, "//linux", "protocol: linux", "path: boot():/EFI/Linux/contract_linux.efi");
        TreeNode wrongKey = child(os, "//kernel-path", "protocol: efi", "kernel_path: boot():/EFI/Linux/contract_linux.efi");
        TreeNode other = child(os, "//other", "protocol: efi", "path: boot():/EFI/Linux/contract_linux-lts.efi");
        TreeNode uuid = child(os, "//uuid", "protocol: efi", "path: uuid(other):/EFI/Linux/contract_linux.efi");
        TreeNode container = child(os, "//container");
        TreeNode nested = child(container, "///nested", "protocol: efi", "path: boot():/EFI/Linux/contract_linux.efi");
        equal(NativeMutations.removeKernel(os, CONFIG, "contract", "linux", true),
                new Result(true, List.of(new DeletionRequest(DeletionKind.FILE, "/work/esp/EFI/Linux/contract_linux.efi"))));
        equal(os.getNodes(), List.of(linux, wrongKey, other, uuid, container));
        equal(container.getNodes(), List.of(nested));
    }

    private static void ukiLayout() {
        record Example(String prefix, String name, String filename) {}
        for (Example example : List.of(
                new Example("contract", "contract_linux.efi", "contract_linux.efi"),
                new Example("contract", "contractual.EFI", "contractual.EFI"),
                new Example("contract", "linux.EFI", "contract_linux.EFI"),
                new Example("", "linux", MACHINE + "_linux.efi"),
                new Example(null, MACHINE + "_linux.efi", MACHINE + "_linux.efi"))) {
            TreeNode os = root();
            child(os, "//selected by path", "protocol: efi", "path: boot():/EFI/Linux/" + example.filename());
            equal(NativeMutations.removeKernel(os, CONFIG, example.prefix(), example.name(), true),
                    new Result(true, List.of(new DeletionRequest(DeletionKind.FILE, "/work/esp/EFI/Linux/" + example.filename()))));
            equal(os.getNodes(), List.of());
        }
    }

    private static void keepFilesSelection() {
        TreeNode os = root();
        child(os, "//custom display", "comment: kernel-id=linux", "protocol: efi", "path: boot():/unrelated.efi");
        child(os, "//linux");
        child(os, "//another display", "comment: kernel-id=linux");
        TreeNode nonemptyID = child(os, "//linux", "comment: kernel-id=other");
        TreeNode fallback = child(os, "//linux-fallback", "comment: kernel-id=linux-fallback");
        TreeNode wrongCase = child(os, "//Linux");
        TreeNode pathOnly = child(os, "//path alone", "protocol: linux", "path: boot():/" + MACHINE + "/linux/vmlinuz");
        TreeNode container = child(os, "//container");
        TreeNode nested = child(container, "///linux", "comment: kernel-id=linux");
        equal(NativeMutations.removeKernelEntry(os, "linux"), new Result(true, List.of()));
        equal(os.getNodes(), List.of(nonemptyID, fallback, wrongCase, pathOnly, container));
        equal(container.getNodes(), List.of(nested));
    }

    private static void emptyOperands() {
        TreeNode os = root();
        TreeNode keep = child(os, "//keep");
        for (String name : new String[] { null, "", " \t" }) {
            equal(NativeMutations.removeKernel(os, CONFIG, "contract", name, false), new Result(false, List.of()));
            equal(NativeMutations.removeKernel(os, CONFIG, "contract", name, true), new Result(false, List.of()));
            equal(NativeMutations.removeKernelEntry(os, name), new Result(false, List.of()));
        }
        LimineManager manager = new LimineManager(os, CONFIG);
        manager.removeKernelEntry("absent");
        check(!manager.isUpdateNeeded, "unmatched entry-only wrapper requested an update");
        manager.removeKernelEntry("keep");
        manager.removeKernelEntry("absent");
        manager.removeKernel(null, true);
        check(manager.isUpdateNeeded && os.getNodes().isEmpty(), "later no-op reset the accumulated update");
        equal(keep.getName(), "//keep");
    }

    private static void pureDeletionRequests() throws IOException {
        Path file = Path.of("/work/esp/EFI/Linux/contract_orphan.efi");
        Files.writeString(file, "must remain until execution");
        TreeNode os = root();
        equal(NativeMutations.removeKernel(os, CONFIG, "contract", "orphan", true),
                new Result(false, List.of(new DeletionRequest(DeletionKind.FILE, file.toString()))));
        equal(Files.readString(file), "must remain until execution");
        Path directory = Path.of("/work/esp", MACHINE, "orphan");
        Files.createDirectories(directory);
        Files.writeString(directory.resolve("keep"), "directory contents");
        equal(NativeMutations.removeKernel(os, CONFIG, "contract", "orphan", false),
                new Result(false, List.of(new DeletionRequest(DeletionKind.DIRECTORY, directory.toString()))));
        equal(Files.readString(directory.resolve("keep")), "directory contents");
        // Even absent files yield logical kernel deletion requests without observation.
        equal(NativeMutations.removeKernel(os, CONFIG, "contract", "never-created", true),
                new Result(false, List.of(new DeletionRequest(DeletionKind.FILE, "/work/esp/EFI/Linux/contract_never-created.efi"))));
    }

    private static void ordinaryKernelDeletion() throws IOException {
        LimineManager manager = new LimineManager(root(), CONFIG);
        manager.removeKernel("orphan", true);
        check(Files.notExists(Path.of("/work/esp/EFI/Linux/contract_orphan.efi")), "file-only wrapper did not delete");
        manager.removeKernel("orphan", false);
        check(Files.notExists(Path.of("/work/esp", MACHINE, "orphan")), "directory-only wrapper did not delete");
        check(!manager.isUpdateNeeded, "file-only removal claimed a tree update");
        Path directoryAtUki = Path.of("/work/esp/EFI/Linux/contract_directory.efi");
        Files.createDirectories(directoryAtUki);
        manager.removeKernel("directory", true);
        check(Files.isDirectory(directoryAtUki), "UKI removal lost its ordinary regular-file check");
        Path fileAtDirectory = Path.of("/work/esp", MACHINE, "plain-file");
        Files.writeString(fileAtDirectory, "keep");
        manager.removeKernel("plain-file", false);
        equal(Files.readString(fileAtDirectory), "keep");

        TreeNode os = root();
        child(os, "//custom normal", "protocol: linux", "path: boot():/" + MACHINE + "/shared/vmlinuz");
        child(os, "//custom fallback", "protocol: linux", "path: boot():/" + MACHINE + "/shared/vmlinuz");
        Path shared = Path.of("/work/esp", MACHINE, "shared");
        Files.createDirectories(shared);
        Files.writeString(shared.resolve("vmlinuz"), "kernel");
        Files.writeString(shared.resolve("initramfs"), "normal");
        Files.writeString(shared.resolve("initramfs-fallback"), "fallback");
        manager = new LimineManager(os, CONFIG);
        manager.removeKernel("shared", false);
        check(manager.isUpdateNeeded && os.getNodes().isEmpty() && Files.notExists(shared), "ordinary shared-directory removal differs");
    }

    private static TreeNode repeatedEntries() {
        TreeNode root = root();
        TreeNode first = child(root, "/+Arch");
        child(first, "  //Snapshots", "comment: first");
        child(first, "  //Snapshots", "comment: second");
        TreeNode second = child(root, "/Arch");
        child(second, "//Snapshots", "comment: third");
        child(root, "/arch");
        return root;
    }

    private static void nthEntry() {
        TreeNode root = repeatedEntries();
        TreeNode cleared = root.getNodes().get(1).getNodes().getFirst();
        equal(NativeMutations.removeEntry(root, "Arch/Snapshots", 3), new Result(true, List.of()));
        equal(render(root), List.of("/+Arch", "  //Snapshots", "comment: first", "  //Snapshots", "comment: second", "/Arch", "", "/arch"));
        check(root.getNodes().get(1).getNodes().getFirst() == cleared, "slash removal detached the cleared node");
        List<String> before = render(root);
        equal(NativeMutations.removeEntry(root, "Arch/Snapshots", 9), new Result(false, List.of()));
        equal(render(root), before);
        check(LimineManager.removeEntry(root, "Arch/Snapshots", 2), "ordinary removeEntry failed");
        equal(render(root), List.of("/+Arch", "  //Snapshots", "comment: first", "", "/Arch", "", "/arch"));
    }

    private static void allEntries() {
        for (int index : new int[] { 0, -1, Integer.MIN_VALUE }) {
            TreeNode root = repeatedEntries();
            equal(NativeMutations.removeEntry(root, "Arch/Snapshots", index), new Result(true, List.of()));
            equal(render(root), List.of("/+Arch", "", "", "/Arch", "", "/arch"));
        }
    }

    private static void blankSegments() {
        TreeNode root = root();
        TreeNode blank = child(root, "/  ");
        child(blank, "//Leaf", "comment: remove");
        TreeNode arch = child(root, "/Arch");
        child(arch, "//   ", "comment: empty leaf");
        equal(NativeMutations.removeEntry(root, "/Leaf", 1), new Result(true, List.of()));
        equal(NativeMutations.removeEntry(root, "Arch/", 0), new Result(true, List.of()));
        equal(render(root), List.of("/  ", "", "/Arch", ""));
    }

    private static void machineDepth() {
        TreeNode root = root();
        TreeNode first = child(root, "/first", "comment: machine-id=" + MACHINE);
        TreeNode nested = child(first, "//nested", "comment: machine-id=" + MACHINE);
        TreeNode second = child(root, "/second", "comment: machine-id=" + MACHINE);
        equal(NativeMutations.removeEntry(root, MACHINE, 2), new Result(true, List.of()));
        equal(nested.getName(), "");
        equal(first.getName(), "/first");
        equal(second.getName(), "/second");
        equal(NativeMutations.removeEntry(root, MACHINE, 1), new Result(true, List.of()));
        equal(root.getNodes(), List.of(first, second));
        equal(render(root), List.of("", "/second", "comment: machine-id=" + MACHINE));
        String upper = "ABCDEFABCDEFABCDEFABCDEFABCDEFAB";
        TreeNode identity = child(root, "/case", "comment: machine-id=" + upper);
        equal(NativeMutations.removeEntry(root, upper.toLowerCase(), 1), new Result(false, List.of()));
        equal(NativeMutations.removeEntry(root, upper, 1), new Result(true, List.of()));
        equal(identity.getName(), "");
    }

    private static void machineRoot() {
        for (int depth : new int[] { 0, -2 }) {
            TreeNode root = root();
            root.addConfigLine("comment: machine-id=" + MACHINE);
            child(root, "/descendant", "comment: machine-id=" + MACHINE);
            equal(NativeMutations.removeEntry(root, MACHINE, depth), new Result(true, List.of()));
            equal(render(root), List.of());
        }
        TreeNode root = root();
        child(root, "/descendant", "comment: machine-id=" + MACHINE);
        equal(NativeMutations.removeEntry(root, MACHINE, 0), new Result(false, List.of()));
    }

    private static void clearSerialization() throws IOException {
        Files.writeString(Path.of("/work/esp/limine.conf"), "timeout: 3\n/+Arch\n  //Drop\n    comment: old\n    ///Child\n      protocol: efi\n  //Keep\n    comment: retained\n");
        TreeNode root = new LimineReader(CONFIG).getRootNode();
        TreeNode drop = root.getNodes().getFirst().getNodes().getFirst();
        drop.setEnableLineBreak(true);
        drop.setOptions(new EntryOptions().setKernelID("old"));
        equal(NativeMutations.removeEntry(root, "Arch/Drop", 1), new Result(true, List.of()));
        equal(render(root), List.of("timeout: 3", "/+Arch", "", "  //Keep", "    comment: retained"));
        equal(drop.getCleanName(), "");
        equal(drop.getOrCreateOptions().getKernelID(), "");
        check(drop.getNodes().isEmpty() && !drop.isEnableLineBreak(), "clear did not reset node state");
    }

    private static void efiOverwrite() throws IOException {
        TreeNode root = root();
        TreeNode incompatible = child(root, "/Tools", "comment: foreign");
        incompatible.setOptions(new EntryOptions().setMachineID(MACHINE));
        TreeNode first = child(root, "/+Tools", "protocol: linux", "comment: old");
        EntryOptions existingOptions = new EntryOptions().setPriority(7);
        first.setOptions(existingOptions);
        first.setEnableLineBreak(false);
        TreeNode nested = child(first, "//Keep child", "comment: retained");
        TreeNode later = child(root, "/Tools", "comment: later");
        Result result = NativeMutations.addEfi(root, "Tools", "replacement", new EntryOptions().setPriority(95).setEntryOverwrite(true),
                new ResolvedEfiLocation("uuid(" + UUID + "):", null, "/EFI/Tools.EFI", "/work/external/EFI/Tools.EFI"));
        equal(result, new Result(true, List.of()));
        equal(root.getNodes(), List.of(incompatible, first, later));
        equal(first.getNodes(), List.of(nested));
        equal(first.getName(), "/+Tools");
        check(first.getOrCreateOptions() == existingOptions && !first.isEnableLineBreak(), "overwrite replaced cached options or line-break state");
        equal(first.getConfigLines(), List.of("### This EFI entry is auto-generated by limine-entry-tool", "comment: replacement",
                "comment: order-priority=95 ", "protocol: efi", "path: uuid(" + UUID + "):/EFI/Tools.EFI", ""));
        equal(later.getConfigLines(), List.of("comment: later"));
    }

    private static void efiInsertion() throws IOException {
        TreeNode root = root();
        TreeNode high = child(root, "/High");
        high.setOptions(new EntryOptions().setPriority(90));
        TreeNode equalPriority = child(root, "/Equal");
        equalPriority.setOptions(new EntryOptions().setPriority(60));
        TreeNode nested = child(equalPriority, "//New", "comment: not top-level");
        TreeNode low = child(root, "/Low");
        low.setOptions(new EntryOptions().setPriority(10));
        equal(NativeMutations.addEfi(root, "New", "", new EntryOptions().setPriority(60), localEfi("/EFI/New.efi", true)), new Result(true, List.of()));
        TreeNode added = root.getNodes().get(2);
        equal(root.getNodes(), List.of(high, equalPriority, added, low));
        equal(added.getName(), "/New");
        check(added.isEnableLineBreak() && added.getMacros() == root.getMacros(), "new EFI node lost native formatting/context");
        equal(equalPriority.getNodes(), List.of(nested));
        equal(added.getConfigLines(), List.of("### This EFI entry is auto-generated by limine-entry-tool", "comment: ",
                "comment: order-priority=60 ", "protocol: efi", "path: boot():/EFI/New.efi", ""));
    }

    private static void efiNoOverwrite() throws IOException {
        TreeNode root = root();
        child(root, "/Tools", "comment: preserve");
        List<String> before = render(root);
        equal(NativeMutations.addEfi(root, "Tools", "new", new EntryOptions(), localEfi("/EFI/Tools.efi", true)), new Result(false, List.of()));
        expectIOException(() -> NativeMutations.addEfi(root, "Tools", "new", new EntryOptions(), localEfi("/EFI/missing.efi", false)));
        expectIOException(() -> NativeMutations.addEfi(root, "Tools", "new", new EntryOptions(),
                new ResolvedEfiLocation(null, UUID, "/EFI/Tools.efi", "/work/external/EFI/Tools.efi")));
        equal(render(root), before);
    }

    private static void nullEfiSelector() {
        TreeNode root = root();
        TreeNode efi = child(root, "/EFI", "protocol: efi", "path: uuid(" + UUID + "):/EFI/Tools.efi");
        LimineEntry entry = new LimineEntry(efi);
        check(!entry.containsEfiPath(null, "/EFI/Tools.efi"), "null path selector matched");
        check(!entry.containsEfiPath(" \t", "/EFI/Tools.efi"), "blank path selector matched");
        check(entry.containsEfiPath(UUID, "/EFI/Tools.efi"), "UUID selector failed after null check");
    }

    private static void efiSelection() {
        TreeNode root = root();
        child(root, "/EFI", "protocol: efi", "path: boot():/EFI/Tools.efi#abc");
        child(root, "/UEFI", "protocol: uefi", "image_path: boot():EFI/TOOLS.EFI/");
        child(root, "/Chainload", "protocol: efi_chainload", "path: uuid(" + UUID + "):/EFI/Tools.efi");
        child(root, "/Guid", "protocol: efi", "path: guid(" + UUID + "):/EFI/Tools.efi");
        TreeNode linux = child(root, "/Linux", "protocol: linux", "path: boot():/EFI/Tools.efi");
        TreeNode handoff = child(root, "/Handoff", "protocol: efi_boot_entry", "path: boot():/EFI/Tools.efi");
        TreeNode kernelPath = child(root, "/KernelPath", "protocol: efi", "kernel_path: boot():/EFI/Tools.efi");
        TreeNode modulePath = child(root, "/ModulePath", "protocol: efi", "module_path: boot():/EFI/Tools.efi");
        TreeNode other = child(root, "/Other", "protocol: efi", "path: boot():/EFI/Tools.efi.backup");
        TreeNode foreign = child(root, "/Foreign", "protocol: efi", "path: uuid(other):/EFI/Tools.efi");
        TreeNode parent = child(root, "/Parent");
        TreeNode nested = child(parent, "//Nested", "protocol: efi", "path: boot():/EFI/Tools.efi");
        equal(NativeMutations.removeEfi(root, new ResolvedEfiLocation("boot():", UUID, "/EFI/Tools.efi", "/work/esp/EFI/Tools.efi"), true), new Result(true, List.of()));
        equal(root.getNodes(), List.of(linux, handoff, kernelPath, modulePath, other, foreign, parent));
        equal(parent.getNodes(), List.of(nested));
    }

    private static void efiNullableSelectors() {
        TreeNode root = root();
        TreeNode boot = child(root, "/Boot", "protocol: efi", "path: boot():/EFI/Tools.efi");
        child(root, "/UUID", "protocol: efi", "path: uuid(" + UUID + "):/EFI/Tools.efi");
        equal(NativeMutations.removeEfi(root, new ResolvedEfiLocation(null, UUID, "/EFI/Tools.efi", null), false), new Result(true, List.of()));
        equal(root.getNodes(), List.of(boot));
        TreeNode unmatched = child(root, "/Unmatched", "protocol: efi", "path: boot():/EFI/Other.efi");
        equal(NativeMutations.removeEfi(root, localEfi("/EFI/Tools.efi", false), false), new Result(true, List.of()));
        equal(root.getNodes(), List.of(unmatched));
        equal(NativeMutations.removeEfi(root, new ResolvedEfiLocation(null, null, "/EFI/Other.efi", "/work/external/EFI/Other.efi"), false), new Result(false, List.of()));
        equal(root.getNodes(), List.of(unmatched));
    }

    private static void efiDeletionRequests() throws IOException {
        TreeNode root = root();
        child(root, "/Missing", "protocol: efi", "path: boot():/EFI/absent.efi");
        equal(NativeMutations.removeEfi(root, localEfi("/EFI/absent.efi", false), false), new Result(true, List.of()));
        equal(root.getNodes(), List.of());
        Path present = Path.of("/work/esp/EFI/file-only.efi");
        Files.writeString(present, "pure calls preserve bytes");
        equal(NativeMutations.removeEfi(root, localEfi("/EFI/file-only.efi", true), false),
                new Result(false, List.of(new DeletionRequest(DeletionKind.FILE, present.toString()))));
        equal(Files.readString(present), "pure calls preserve bytes");
        child(root, "/Keep files", "protocol: efi", "path: boot():/EFI/file-only.efi");
        equal(NativeMutations.removeEfi(root, localEfi("/EFI/file-only.efi", true), true), new Result(true, List.of()));
        equal(Files.readString(present), "pure calls preserve bytes");
    }

    private static void ordinaryEfi() throws IOException {
        TreeNode root = root();
        TreeNode existing = child(root, "/Tools", "comment: preserve");
        List<String> before = render(root);
        expectIOException(() -> LimineManager.addEfi(root, "Tools", "new", new EntryOptions(), "/work/esp/EFI/not-created.efi", CONFIG));
        Path outsideMount = Path.of("/work/not-on-supported-mount.efi");
        Files.writeString(outsideMount, "existing but unsupported");
        expectIOException(() -> LimineManager.addEfi(root, "Tools", "new", new EntryOptions(), outsideMount.toString(), CONFIG));
        equal(render(root), before);
        Path file = Path.of("/work/esp/EFI/Tools.efi");
        Files.writeString(file, "local EFI");
        check(!LimineManager.addEfi(root, "Tools", "new", new EntryOptions(), file.toString(), CONFIG), "no-overwrite changed a valid existing entry");
        check(LimineManager.addEfi(root, "Tools", "new", new EntryOptions().setEntryOverwrite(true), file.toString(), CONFIG), "valid overwrite failed");
        equal(root.getNodes(), List.of(existing));
        check(existing.getConfigLines().contains("path: boot():/EFI/Tools.efi"), "local mount did not produce boot URI");
        child(root, "/Unmatched", "protocol: efi", "path: boot():/EFI/unmatched.efi");
        check(LimineManager.removeEfiPath(root, file.toString(), CONFIG, true), "keep-files wrapper did not select");
        equal(Files.readString(file), "local EFI");
        check(!LimineManager.removeEfiPath(root, file.toString(), CONFIG, false), "file-only wrapper claimed tree change");
        check(Files.notExists(file), "file-only EFI wrapper did not execute deletion");
        child(root, "/Missing", "protocol: efi", "path: boot():/EFI/Tools.efi");
        check(LimineManager.removeEfiPath(root, file.toString(), CONFIG, false), "missing file prevented entry removal");
        check(!LimineManager.removeEfiPath(root, null, CONFIG, false) && !LimineManager.removeEfiPath(root, " ", CONFIG, false), "blank EFI operand changed tree");
        check(!LimineManager.removeEfiPath(root, outsideMount.toString(), CONFIG, false), "unsupported mount removal succeeded");
        equal(Files.readString(outsideMount), "existing but unsupported");
        Path emptyDirectory = Path.of("/work/esp/EFI/empty-directory.efi");
        Files.createDirectories(emptyDirectory);
        check(!LimineManager.removeEfiPath(root, emptyDirectory.toString(), CONFIG, false), "file-only EFI removal claimed a tree update");
        check(Files.notExists(emptyDirectory), "EFI wrapper imposed the UKI regular-file check on deleteFile");

        Path external = Path.of("/work/external/EFI/Tools.efi");
        Files.writeString(external, "external EFI");
        check(LimineManager.addEfi(root, "External", "", new EntryOptions(), external.toString(), CONFIG), "resolved external add failed");
        check(root.getNodes().getLast().getConfigLines().contains("path: uuid(" + UUID + "):/EFI/Tools.efi"), "external mount did not produce UUID URI");
        // Empty fixture /sys means stock removal has no external selector.
        check(!LimineManager.removeEfiPath(root, external.toString(), CONFIG, false), "non-EFI external removal was admitted");
        equal(Files.readString(external), "external EFI");
    }

    private static void immutableResults() {
        ArrayList<DeletionRequest> input = new ArrayList<>();
        input.add(new DeletionRequest(DeletionKind.FILE, "/work/frozen.efi"));
        Result result = new Result(false, input);
        input.clear();
        equal(result.deletions(), List.of(new DeletionRequest(DeletionKind.FILE, "/work/frozen.efi")));
        try {
            result.deletions().clear();
            throw new AssertionError("result deletion list is mutable");
        } catch (UnsupportedOperationException expected) {
            // Immutable logical requests, independent of treeChanged.
        }
    }

    private static void additionRegression() throws IOException {
        Config config = new Config(MACHINE, "Fixture Linux", "/work/esp", "boot():");
        Files.writeString(Path.of("/work/vmlinuz"), "new kernel");
        Files.writeString(Path.of("/work/initramfs"), "new initramfs");
        Files.writeString(Path.of("/work/input.efi"), "new UKI");
        TreeNode os = root();
        LimineManager manager = new LimineManager(os, config, Map.of("default", "root=fixture quiet"));
        manager.addKernel("linux", "kernel comment", new EntryOptions(), "/work/initramfs", "/work/vmlinuz", "-fallback");
        TreeNode kernel = os.getNodes().getFirst();
        equal(kernel.getCleanName(), "linux-fallback");
        equal(kernel.getConfigLines(), List.of("  ### This kernel entry is auto-generated by limine-entry-tool", "  comment: kernel comment",
                "  comment: kernel-id=linux-fallback ", "  protocol: linux", "  module_path: boot():/" + MACHINE + "/linux/initramfs",
                "  path: boot():/" + MACHINE + "/linux/vmlinuz", "  cmdline: root=fixture quiet", ""));
        equal(Files.readString(Path.of("/work/esp", MACHINE, "linux", "vmlinuz")), "new kernel");
        equal(Files.readString(Path.of("/work/esp", MACHINE, "linux", "initramfs")), "new initramfs");
        manager.addUki("regression", "UKI comment", new EntryOptions(), "/work/input.efi");
        TreeNode uki = os.getNodes().getFirst();
        equal(uki.getCleanName(), "regression");
        equal(uki.getConfigLines(), List.of("  ### This kernel entry is auto-generated by limine-entry-tool", "  comment: UKI comment",
                "  comment: kernel-id=regression ", "  protocol: efi", "  path: boot():/EFI/Linux/contract_regression.efi",
                "  cmdline: root=fixture quiet", ""));
        equal(Files.readString(Path.of("/work/esp/EFI/Linux/contract_regression.efi")), "new UKI");
        check(manager.isUpdateNeeded && os.getNodes().getLast() == kernel, "addition ordering/update changed");
    }

    private static ResolvedEfiLocation localEfi(String path, boolean present) {
        return new ResolvedEfiLocation("boot():", null, path, present ? "/work/esp" + path : null);
    }

    private static TreeNode root() { return new TreeNode("root", 0, null); }

    private static TreeNode child(TreeNode parent, String name, String... lines) {
        TreeNode node = new TreeNode(name, 1, parent.getName(), parent.getMacros());
        node.getConfigLines().addAll(List.of(lines));
        parent.addNode(node);
        return node;
    }

    private static List<String> render(TreeNode root) { return new LimineWriter(CONFIG).render(root); }

    private static void equal(Object actual, Object expected) {
        if (!Objects.equals(actual, expected)) throw new AssertionError("expected " + expected + ", got " + actual);
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void expectIOException(Checked action) {
        try {
            action.run();
            throw new AssertionError("expected IOException");
        } catch (IOException expected) {
            // Resolved-input rejection must precede no-overwrite selection.
        } catch (Exception other) {
            throw new AssertionError("wrong exception", other);
        }
    }

    private static void run(String name, Checked action) throws Exception {
        try {
            action.run();
            passed++;
        } catch (Exception | AssertionError failure) {
            throw new AssertionError(name, failure);
        }
    }

    @FunctionalInterface
    private interface Checked { void run() throws Exception; }
}
