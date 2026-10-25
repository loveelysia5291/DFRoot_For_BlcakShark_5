package df.root;

/** Implemented by the UI so the deploy can report a real percentage. */
interface IProgress {
    void progress(int percent);
}
