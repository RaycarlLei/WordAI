package org.wordai.community.word_a_i;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsContract.Root;
import android.provider.DocumentsProvider;
import java.io.FileNotFoundException;

/** Platform-only code: this test APK provider runs outside the instrumented app. */
public final class BackupTestDocumentsProvider extends DocumentsProvider {
    public static final String AUTHORITY = "org.wordai.community.word_a_i.test.documents";
    public static final String ROOT_TITLE = "WordAI test storage";
    private static final String ROOT_ID = "root";
    private static final String[] ROOT_COLUMNS = {Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID,
        Root.COLUMN_TITLE, Root.COLUMN_SUMMARY, Root.COLUMN_FLAGS, Root.COLUMN_ICON,
        Root.COLUMN_MIME_TYPES, Root.COLUMN_AVAILABLE_BYTES};
    private static final String[] DOCUMENT_COLUMNS = {Document.COLUMN_DOCUMENT_ID,
        Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS,
        Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED};

    @Override public boolean onCreate() {
        SyntheticDocuments.initialize(getContext());
        return true;
    }

    @Override public Cursor queryRoots(String[] projection) {
        MatrixCursor cursor = new MatrixCursor(projection == null ? ROOT_COLUMNS : projection);
        MatrixCursor.RowBuilder row = cursor.newRow();
        for (String column : cursor.getColumnNames()) {
            switch (column) {
                case Root.COLUMN_ROOT_ID: row.add("synthetic"); break;
                case Root.COLUMN_DOCUMENT_ID: row.add(ROOT_ID); break;
                case Root.COLUMN_TITLE: row.add(ROOT_TITLE); break;
                case Root.COLUMN_SUMMARY: row.add("Instrumentation fixture"); break;
                case Root.COLUMN_FLAGS: row.add(Root.FLAG_SUPPORTS_CREATE | Root.FLAG_LOCAL_ONLY); break;
                case Root.COLUMN_ICON: row.add(android.R.drawable.ic_menu_save); break;
                case Root.COLUMN_MIME_TYPES: row.add("application/json"); break;
                case Root.COLUMN_AVAILABLE_BYTES: row.add(16L * 1024 * 1024); break;
                default: row.add(null);
            }
        }
        return cursor;
    }

    @Override public Cursor queryDocument(String id, String[] projection) throws FileNotFoundException {
        MatrixCursor cursor = new MatrixCursor(projection == null ? DOCUMENT_COLUMNS : projection);
        addDocument(cursor, id);
        return cursor;
    }

    @Override public Cursor queryChildDocuments(String parent, String[] projection, String sortOrder)
            throws FileNotFoundException {
        requireRoot(parent);
        MatrixCursor cursor = new MatrixCursor(projection == null ? DOCUMENT_COLUMNS : projection);
        for (String id : SyntheticDocuments.ids()) addDocument(cursor, id);
        return cursor;
    }

    @Override public String createDocument(String parent, String mimeType, String name)
            throws FileNotFoundException {
        requireRoot(parent);
        if (!"application/json".equals(mimeType)) throw new FileNotFoundException("Unexpected fixture type");
        return SyntheticDocuments.create(name);
    }

    @Override public ParcelFileDescriptor openDocument(String id, String mode, CancellationSignal signal)
            throws FileNotFoundException {
        SyntheticDocuments.Saved saved = SyntheticDocuments.get(id);
        if (mode.contains("w")) {
            SyntheticDocuments.opened(id);
            if (saved.name.startsWith("stall-")) return SyntheticDocuments.gatedPipe(id);
            if (saved.name.startsWith("open-failure-")) throw new FileNotFoundException("Synthetic open failure");
            if (saved.name.startsWith("write-failure-")) {
                // A real descriptor that refuses writes, not a mocked OutputStream.
                return ParcelFileDescriptor.open(saved.file, ParcelFileDescriptor.MODE_READ_ONLY);
            }
        }
        return ParcelFileDescriptor.open(saved.file, ParcelFileDescriptor.parseMode(mode));
    }

    @Override public boolean isChildDocument(String parent, String id) {
        return ROOT_ID.equals(parent) && SyntheticDocuments.ids().contains(id);
    }

    private void addDocument(MatrixCursor cursor, String id) throws FileNotFoundException {
        boolean root = ROOT_ID.equals(id);
        SyntheticDocuments.Saved saved = root ? null : SyntheticDocuments.get(id);
        MatrixCursor.RowBuilder row = cursor.newRow();
        for (String column : cursor.getColumnNames()) {
            switch (column) {
                case Document.COLUMN_DOCUMENT_ID: row.add(id); break;
                case Document.COLUMN_DISPLAY_NAME: row.add(root ? ROOT_TITLE : saved.name); break;
                case Document.COLUMN_MIME_TYPE: row.add(root ? Document.MIME_TYPE_DIR : "application/json"); break;
                case Document.COLUMN_FLAGS: row.add(root ? Document.FLAG_DIR_SUPPORTS_CREATE : Document.FLAG_SUPPORTS_WRITE); break;
                case Document.COLUMN_SIZE: row.add(root ? 0L : saved.file.length()); break;
                case Document.COLUMN_LAST_MODIFIED: row.add(root ? 0L : saved.file.lastModified()); break;
                default: row.add(null);
            }
        }
    }

    private static void requireRoot(String id) throws FileNotFoundException {
        if (!ROOT_ID.equals(id)) throw new FileNotFoundException("Unknown fixture parent");
    }
}
