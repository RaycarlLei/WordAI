package org.wordai.community.word_a_i;

import android.content.Context;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

final class SyntheticDocuments {
    static final class Saved {
        final String name;
        final File file;
        int writeOpens;
        final CountDownLatch entered = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final CountDownLatch drained = new CountDownLatch(1);
        Saved(String name, File file) { this.name = name; this.file = file; }
    }

    private static File directory;
    private static final Map<String, Saved> documents = new LinkedHashMap<>();

    static synchronized void initialize(Context context) {
        if (directory != null) return;
        directory = new File(context.getCacheDir(), "synthetic-backup-documents");
        if (!directory.isDirectory() && !directory.mkdir()) throw new IllegalStateException("Cannot create fixture directory");
    }

    static synchronized String create(String name) throws FileNotFoundException {
        if (name.length() > 128 || !name.matches("[A-Za-z0-9._-]+\\.json")) throw new FileNotFoundException("Invalid fixture name");
        String id = UUID.randomUUID().toString();
        File file = new File(directory, id);
        try {
            if (!file.createNewFile()) throw new IOException("Fixture collision");
        } catch (IOException error) {
            throw new FileNotFoundException("Cannot create fixture document");
        }
        documents.put(id, new Saved(name, file));
        return id;
    }

    static synchronized List<String> ids() { return new ArrayList<>(documents.keySet()); }
    static synchronized Saved get(String id) throws FileNotFoundException {
        Saved saved = documents.get(id);
        if (saved == null) throw new FileNotFoundException("Unknown fixture document");
        return saved;
    }
    static synchronized void opened(String id) throws FileNotFoundException { get(id).writeOpens++; }

    static ParcelFileDescriptor gatedPipe(String id) throws FileNotFoundException {
        Saved saved = get(id);
        try {
            ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
            Thread reader = new Thread(() -> {
                try (ParcelFileDescriptor.AutoCloseInputStream input = new ParcelFileDescriptor.AutoCloseInputStream(pipe[0]);
                     java.io.FileOutputStream output = new java.io.FileOutputStream(saved.file)) {
                    int first = input.read();
                    if (first < 0) return;
                    output.write(first);
                    output.flush();
                    saved.entered.countDown();
                    if (!saved.release.await(10, TimeUnit.SECONDS)) return;
                    byte[] buffer = new byte[8192];
                    int count;
                    while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                } catch (IOException | InterruptedException error) {
                    // Failure closes the pipe, so a blocked real writer is released.
                } finally {
                    saved.drained.countDown();
                }
            }, "synthetic-backup-pipe");
            reader.setDaemon(true);
            reader.start();
            return pipe[1];
        } catch (IOException error) {
            throw new FileNotFoundException("Cannot create fixture pipe");
        }
    }

    static void gate(String id, String operation) {
        try {
            Saved saved = get(id);
            if (operation.equals("release")) saved.release.countDown();
            else if (!(operation.equals("entered") ? saved.entered : saved.drained).await(5, TimeUnit.SECONDS)) {
                throw new IllegalStateException("Fixture rendezvous timed out");
            }
        } catch (FileNotFoundException | InterruptedException error) {
            throw new IllegalStateException("Fixture rendezvous failed", error);
        }
    }

    static synchronized Bundle inspect() {
        Bundle value = new Bundle();
        value.putInt("created", documents.size());
        value.putInt("writeOpens", documents.values().stream().mapToInt(saved -> saved.writeOpens).sum());
        for (Map.Entry<String, Saved> entry : documents.entrySet()) {
            Saved saved = entry.getValue();
            value.putString("uri", DocumentsContract.buildDocumentUri(BackupTestDocumentsProvider.AUTHORITY, entry.getKey()).toString());
            value.putString("name", saved.name);
            try (FileInputStream input = new FileInputStream(saved.file);
                 ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[8192];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    if (output.size() + count > 512 * 1024) throw new IOException("Fixture size exceeded");
                    output.write(buffer, 0, count);
                }
                value.putByteArray("bytes", output.toByteArray());
            } catch (IOException error) {
                throw new IllegalStateException("Cannot inspect fixture bytes", error);
            }
        }
        return value;
    }

    static synchronized void reset() {
        // Only registered files created here are removed; no recursive or user-path deletion.
        for (Saved saved : documents.values()) {
            saved.release.countDown();
            try {
                if (!saved.file.getCanonicalFile().getParentFile().equals(directory.getCanonicalFile())) {
                    throw new IOException("Fixture path escaped");
                }
                if (!saved.file.delete() && saved.file.exists()) throw new IOException("Cannot remove fixture");
            } catch (IOException error) {
                throw new IllegalStateException("Cannot reset fixture", error);
            }
        }
        documents.clear();
    }
}
