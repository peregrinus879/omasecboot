package org.limine.entry.tool;

import org.limine.entry.tool.objects.BootOptions;
import org.limine.entry.tool.objects.Config;
import org.limine.entry.tool.processes.JsonOutput;
import org.limine.entry.tool.processes.LimineReader;
import org.limine.entry.tool.processes.ReadObservation;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Map;

/** Deterministic reader-generation and lazy-macro interleaving contracts. */
public class DescriptionContract {
    private static final String ID = "11111111111111111111111111111111";

    private static Config config(String directory, String name) {
        return new Config(ID, name, directory, "boot():");
    }

    private static String tree(String os, String kernel) {
        return "${kid}=" + kernel + "\n/" + os + "\n  comment: machine-id=" + ID
                + "\n//Displayed kernel\n  comment: kernel-id=${kid}\n  protocol: efi\n";
    }

    public static void main(String[] args) throws Exception {
        String operation = args[0];
        if (operation.equals("json")) {
            System.out.println(JsonOutput.encode(Map.of("text", "quote\" slash\\ tab\t newline\n control\u0001 emoji\ud83d\ude00")));
            return;
        }
        if (operation.equals("pure-clean")) {
            var value = BootOptions.cleanKernelParameters("root=fixture initrd=/microcode", true);
            System.out.println(JsonOutput.encode(Map.of("cmdline", value.cmdline(), "initrds", value.initrds().stream().toList())));
            return;
        }

        Path a = Path.of("/work/a");
        Path b = Path.of("/work/b");
        Files.createDirectories(a);
        Files.createDirectories(b);
        if (operation.equals("interleaved")) {
            Files.writeString(a.resolve("limine.conf"), tree("A", "linux-a"));
            Files.writeString(b.resolve("limine.conf"), tree("B", "linux-b"));
            LimineReader first = new LimineReader(config(a.toString(), "A"), new ReadObservation());
            LimineReader second = new LimineReader(config(b.toString(), "B"), new ReadObservation());
            if (first.getTargetOsNode().findKernelCandidates("linux-a").size() != 1
                    || second.getTargetOsNode().findKernelCandidates("linux-b").size() != 1) {
                throw new AssertionError("one reader replaced another reader's macro state");
            }
            LimineReader deferred = new LimineReader(config(a.toString(), "A"), new ReadObservation());
            Files.writeString(b.resolve("limine.conf"), "${kid}=wrong\n/${undefined}\n");
            try {
                new LimineReader(config(b.toString(), "B"), new ReadObservation());
                throw new AssertionError("undefined macro was accepted");
            } catch (IllegalArgumentException expected) {
                // A failed read must not alter the previous successful tree.
            }
            if (deferred.getTargetOsNode().findKernelCandidates("linux-a").size() != 1) {
                throw new AssertionError("failed reader contaminated an existing tree");
            }
        } else {
            Path path = a.resolve("limine.conf");
            String text = tree("Old", "linux");
            if (!operation.equals("as-read-create")) Files.writeString(path, text);
            LimineReader captured = new LimineReader(config(a.toString(), "Old"), new ReadObservation());
            Map<String, Object> observation = captured.getConfigurationObservation();
            switch (operation) {
                case "as-read-replace" -> {
                    Path replacement = a.resolve("replacement");
                    Files.writeString(replacement, tree("New", "other"));
                    Files.move(replacement, path, StandardCopyOption.REPLACE_EXISTING);
                }
                case "as-read-delete" -> Files.delete(path);
                case "as-read-create" -> Files.writeString(path, tree("New", "other"));
                default -> throw new IllegalArgumentException("Unknown fixture operation");
            }
            if (!observation.equals(captured.getConfigurationObservation())) {
                throw new AssertionError("reader replaced its captured observation");
            }
            if (operation.equals("as-read-create")) {
                if (!observation.get("status").equals("absent") || !captured.getRootNode().getNodes().isEmpty()) {
                    throw new AssertionError("new configuration was attached to an absent read");
                }
            } else {
                String hash = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(text.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
                if (!hash.equals(observation.get("sha256"))
                        || !captured.getTargetOsNode().getCleanName().equals("Old")) {
                    throw new AssertionError("tree is not bound to its originally read bytes");
                }
            }
        }
        System.out.println(JsonOutput.encode(Map.of("validated", operation)));
    }
}
