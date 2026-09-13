import org.limine.entry.tool.objects.Config;
import org.limine.entry.tool.objects.EntryOptions;
import org.limine.entry.tool.processes.BootResources;
import org.limine.entry.tool.processes.LimineManager;
import org.limine.entry.tool.processes.LimineReader;
import org.limine.entry.tool.processes.LimineWriter;
import org.limine.entry.tool.processes.Utility;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class BootResourceContract {
    public static void main(String[] args) throws Exception {
        String machine = "11111111111111111111111111111111";
        Config.QUIET = true;
        Config.ENABLE_VERIFICATION = false;
        Config.UKI_FILE_PREFIX = "contract";
        Config config = new Config(machine, "Contract Linux", "/boot", "boot():");
        Files.createDirectories(Path.of("/boot"));
        Files.writeString(Path.of("/boot/limine.conf"), "/+Contract Linux\n  comment: machine-id=" + machine + "\n");
        Files.writeString(Path.of("/work/hash-mode"), "pass\n");
        Files.writeString(Path.of("/work/sync-mode"), "pass\n");
        Files.writeString(Path.of("/work/input.efi"), "fixture UKI\n");
        LimineReader reader = new LimineReader(config);
        Map<String, String> options = new HashMap<>(Map.of("default", "root=first"));
        LimineManager manager = new LimineManager(reader.getTargetOsNode(), config, options);
        options.put("default", "root=second");
        manager.addUki("custom", "", new EntryOptions(), "/work/input.efi");
        new LimineWriter(config).save(reader.getRootNode());
        String published = Files.readString(Path.of("/boot/limine.conf"));
        if (!published.contains("cmdline: root=first") || published.contains("root=second")) {
            throw new AssertionError("Publisher did not retain its captured command-line map");
        }

        Path kernelDirectory = Path.of("/boot", machine, "linux");
        Files.createDirectories(kernelDirectory);
        Files.writeString(kernelDirectory.resolve("initramfs"), "old initramfs");
        Files.writeString(kernelDirectory.resolve("vmlinuz"), "old kernel");
        Files.writeString(Path.of("/work/initramfs"), "new initramfs");
        Files.writeString(Path.of("/work/vmlinuz"), "new kernel");
        manager = new LimineManager(reader.getTargetOsNode(), config, Map.of("default", "root=fixture initrd=/missing"));
        boolean refused = false;
        try {
            manager.addKernel("linux", "", new EntryOptions(), "/work/initramfs", "/work/vmlinuz", "");
        } catch (IOException expected) {
            refused = true;
        }
        if (!refused || !Files.readString(kernelDirectory.resolve("initramfs")).equals("old initramfs")
                || !Files.readString(kernelDirectory.resolve("vmlinuz")).equals("old kernel")) {
            throw new AssertionError("Missing extra input allowed an earlier destination replacement");
        }

        Files.writeString(Path.of("/work/prepared.efi"), "prepared final bytes");
        Path destination = Path.of("/boot/EFI/Linux/contract_custom.efi");
        String old = Files.readString(destination);
        BootResources.Addition addition = BootResources.uki(config, "contract", "custom", "/work/input.efi", "root=first");
        List<String> rendered = BootResources.render(config, addition, List.of(), "  ",
                resource -> "/work/prepared.efi", (resource, input) -> ":" + Utility.computeBlake2(input));
        String preparedHash = Utility.computeBlake2("/work/prepared.efi");
        if (rendered.stream().noneMatch(line -> line.contains("contract_custom.efi:" + preparedHash))
                || !Files.readString(destination).equals(old)) {
            throw new AssertionError("Renderer did not use prepared bytes without publishing them");
        }
        System.out.println("Passed 3 shared-resource publication contracts.");
    }
}
