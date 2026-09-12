package org.limine.entry.tool;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/** Exercise the same owned-mount scope used by the production scanner. */
public class NativeScannerContract {
    public static void main(String[] args) throws Exception {
        IOException publicationFailure = null;
        try (Main.EfiMount mount = new Main.EfiMount("/run/let")) {
            if (args[0].equals("publication-failure") || args[0].equals("both-fail")) {
                publicationFailure = new IOException("fixture publication failed");
                throw publicationFailure;
            }
        } catch (IOException e) {
            if (args[0].equals("success")) {
                throw new AssertionError("successful cleanup failed", e);
            }
            if (publicationFailure != null && e != publicationFailure) {
                throw new AssertionError("cleanup replaced the publication failure", e);
            }
            if (args[0].equals("both-fail") && e.getSuppressed().length != 1) {
                throw new AssertionError("cleanup failure was not retained", e);
            }
            if (args[0].equals("cleanup-failure") && !e.getMessage().equals("Failed to unmount: /run/let")) {
                throw new AssertionError("unexpected cleanup failure", e);
            }
            Files.writeString(Path.of("/work/scanner-validated"), "expected-failure");
            throw e;
        }
        if (!args[0].equals("success")) {
            throw new AssertionError("expected operation failure was lost");
        }
        Files.writeString(Path.of("/work/scanner-validated"), "success");
    }
}
