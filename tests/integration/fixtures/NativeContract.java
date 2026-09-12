package org.limine.entry.tool;

import org.limine.entry.tool.objects.Config;
import org.limine.entry.tool.objects.EntryOptions;
import org.limine.entry.tool.processes.LimineManager;
import org.limine.entry.tool.processes.LimineReader;
import org.limine.entry.tool.processes.LimineWriter;
import org.limine.entry.tool.processes.Utility;

import java.nio.file.Files;
import java.nio.file.Path;

/** Actual publisher classes with a fixture Config, not a replacement publisher. */
public class NativeContract {
    public static void main(String[] args) throws Exception {
        String operation = args[0];
        String esp = args[1];
        String kernel = args[2];
        Config config = new Config("11111111111111111111111111111111", "Contract Linux", esp, "boot():");
        Config.UKI_FILE_PREFIX = args[3].equals("default") ? null : args[3];
        Config.ENABLE_VERIFICATION = args[4].equals("yes");
        Config.ENABLE_COLOR = false;
        Config.ENABLE_UNICODE = false;

        if (operation.equals("mkdir")) {
            Utility.ensureDirectoryExists(esp + "/directory");
            return;
        }
        if (operation.equals("copy-missing")) {
            Utility.copyFileIfMissingOrDifferent("/work/absent", "/work/absent");
            return;
        }
        if (operation.equals("hash")) {
            Files.writeString(Path.of("/work/hash.result"), Utility.computeBlake2("/work/input.efi"));
            return;
        }
        if (operation.equals("hash-interrupted")) {
            Thread.currentThread().interrupt();
            try {
                Utility.computeBlake2("/work/input.efi");
            } finally {
                boolean interrupted = Thread.interrupted();
                Files.writeString(Path.of("/work/interrupted"), Boolean.toString(interrupted));
            }
            return;
        }
        if (operation.equals("cli-missing")) {
            Main.main(new String[]{kernel});
            return;
        }

        LimineReader reader = new LimineReader(config);
        LimineManager manager = new LimineManager(reader.getTargetOsNode(), config);
        LimineWriter writer = new LimineWriter(config);
        switch (operation) {
            case "uki" -> manager.addUki(kernel, "fixture kernel", new EntryOptions(), "/work/input.efi");
            case "uki-special" -> manager.addUki(kernel, "fixture kernel", new EntryOptions(), "/work/input $(>pwned).efi");
            case "uki-escaped" -> manager.addUki(kernel, "fixture kernel", new EntryOptions(), "/work/input\nline.efi");
            case "uki-same-path" -> manager.addUki(kernel, "fixture kernel", new EntryOptions(), esp + "/EFI/Linux/contract_linux.efi");
            case "regular" -> manager.addKernel(kernel, "fixture kernel", new EntryOptions(), "/work/initramfs", "/work/vmlinuz", "");
            case "regular-fallback" -> manager.addKernel(kernel, "fixture fallback", new EntryOptions(), "/work/initramfs-fallback", "/work/vmlinuz", "-fallback");
            case "efi" -> {
                if (LimineManager.addEfi(reader.getRootNode(), "Fixture EFI", "fixture", new EntryOptions(), "/work/input.efi", config)) {
                    writer.backup();
                    writer.save(reader.getRootNode());
                }
                return;
            }
            case "writer" -> {
                reader.getRootNode().addConfigLine("# newly published fixture");
                writer.backup();
                writer.save(reader.getRootNode());
                return;
            }
            default -> throw new IllegalArgumentException("Unknown fixture operation: " + operation);
        }
        if (manager.isUpdateNeeded) {
            writer.backup();
            writer.save(reader.getRootNode());
        }
    }
}
