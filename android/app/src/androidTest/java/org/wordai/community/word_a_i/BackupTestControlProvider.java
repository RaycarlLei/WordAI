package org.wordai.community.word_a_i;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.provider.DocumentsContract;
import java.io.FileNotFoundException;
import java.util.Arrays;

/** Inspect synthetic bytes without pre-granting the application the SAF URI. */
public final class BackupTestControlProvider extends ContentProvider {
    @Override public boolean onCreate() {
        SyntheticDocuments.initialize(getContext());
        return true;
    }

    @Override public Bundle call(String method, String arg, Bundle extras) {
        String[] callers = getContext().getPackageManager().getPackagesForUid(Binder.getCallingUid());
        if (callers == null || Arrays.stream(callers).noneMatch(name ->
                name.equals("org.wordai.community.word_a_i") || name.equals(getContext().getPackageName()))) {
            throw new SecurityException("Only the synthetic test application may control the fixture");
        }
        if (method.equals("reset")) {
            SyntheticDocuments.reset();
            return Bundle.EMPTY;
        }
        if (method.equals("inspect")) return SyntheticDocuments.inspect();
        if (method.equals("prepare-stall")) {
            try {
                String id = SyntheticDocuments.create("stall-deadline.json");
                Uri uri = DocumentsContract.buildDocumentUri(BackupTestDocumentsProvider.AUTHORITY, id);
                getContext().grantUriPermission("org.wordai.community.word_a_i", uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                Bundle result = new Bundle();
                result.putString("id", id);
                result.putString("uri", uri.toString());
                return result;
            } catch (FileNotFoundException error) {
                throw new IllegalStateException("Cannot prepare fixture", error);
            }
        }
        if (method.equals("entered") || method.equals("release") || method.equals("drained")) {
            SyntheticDocuments.gate(arg, method);
            return Bundle.EMPTY;
        }
        throw new IllegalArgumentException("Unknown fixture operation");
    }

    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) { return null; }
    @Override public String getType(Uri uri) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
