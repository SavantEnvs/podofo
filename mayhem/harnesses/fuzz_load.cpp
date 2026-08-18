// fuzz_load.cpp -- core PDF ingestion surface.
//
// Loads the fuzzer input as a PDF entirely FROM MEMORY (PdfMemDocument::LoadFromBuffer --
// no filesystem I/O, so the harness is unaffected by Mayhem's cwd/read-only-image quirks),
// then walks the object graph enough to force real parsing to happen: the page tree, each
// page's inherited attributes (MediaBox/rotation), its annotations, and its DECODED content
// stream (PdfCanvas::GetContentsCopy() runs the filter chain -- FlateDecode/LZW/ASCII85/
// RunLength/DCT/CCITT -- over attacker-controlled stream bytes). A lazy loader would
// otherwise parse almost nothing just from LoadFromBuffer + GetPages().
//
// PoDoFo throws PoDoFo::PdfError (a std::exception) on malformed input -- that is the
// EXPECTED outcome for a corpus of mostly-invalid PDFs, not a finding, so it is caught here.
// We deliberately do NOT catch (...) -- sanitizer aborts (ASan/UBSan) never unwind as a C++
// exception, so they still surface as real Mayhem findings.
//
// Bounds (SPEC 6b): malformed PDFs are a classic source of hangs (xref loops, deeply
// recursive/self-referencing object graphs) and OOM (huge declared lengths, filter bombs).
// We cap the input size and the number of pages/annotations walked per input so one
// pathological testcase cannot stall the whole campaign; we do NOT cap or catch bad_alloc
// from the content-stream decode itself, since an unbounded decoder allocation is exactly
// the kind of OOM finding we want Mayhem to keep.
#include <podofo/podofo.h>

#include <cstddef>
#include <cstdint>

using namespace PoDoFo;

// A handful of MB is plenty to reach every code path in a PDF this small; bigger inputs
// mostly just mean bigger internal allocations for the same coverage. Keeps runs fast.
static constexpr size_t kMaxInputSize = 4 * 1024 * 1024;

// Guard against a maliciously huge /Count or a pathological page tree: walk at most this
// many pages/annotations per input. This narrows a genuine non-terminating precondition
// (a huge page count is not itself a bug) without masking crashes/OOM found while walking.
static constexpr unsigned kMaxPagesWalked = 64;
static constexpr unsigned kMaxAnnotsPerPage = 64;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    if (size == 0 || size > kMaxInputSize)
        return 0;

    try
    {
        PdfMemDocument doc;
        doc.LoadFromBuffer(bufferview(reinterpret_cast<const char*>(data), size));

        auto& pages = doc.GetPages();
        unsigned count = pages.GetCount();
        unsigned walk = count < kMaxPagesWalked ? count : kMaxPagesWalked;
        for (unsigned i = 0; i < walk; i++)
        {
            auto& page = pages.GetPageAt(i);

            // Inherited attributes -- walks parent /Pages nodes.
            (void)page.GetRect();
            (void)page.GetRotation();

            // Annotations dictionary/array.
            unsigned annotCount = 0;
            for (auto annot : page.GetAnnotations())
            {
                (void)annot;
                if (++annotCount >= kMaxAnnotsPerPage)
                    break;
            }

            // Decode the content stream through the full filter chain. Intentionally
            // unbounded (no size cap on the result) -- a huge/OOM-triggering decode here
            // is a real finding, not something to mask.
            (void)page.GetContentsCopy();
        }
    }
    catch (const PdfError&)
    {
        // Malformed PDF -- the expected outcome for most of the corpus.
    }
    catch (const std::exception&)
    {
        // e.g. std::bad_alloc/std::length_error/std::out_of_range from a rejected
        // pathological declared length -- also an expected rejection, not a finding.
    }

    return 0;
}
