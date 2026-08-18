// fuzz_load_text.cpp -- text-extraction surface (font/CMap/encoding machinery).
//
// Same in-memory load + bounded page walk as fuzz_load, but additionally calls
// PdfPage::ExtractTextTo() on every walked page. Text extraction is where PoDoFo's content
// stream tokenizer, font program parsing (Type1/TrueType/CFF via FreeType), CMap/encoding
// tables, and Unicode mapping all get exercised together -- a very bug-rich area distinct
// from fuzz_load's filter-chain-only walk (that harness never touches font/CMap code at
// all unless a page happens to fail before reaching this point).
//
// Same exception-handling contract as fuzz_load: PdfError (and other std::exception, e.g.
// bad_alloc on a rejected pathological size) is the expected outcome for malformed input
// and is swallowed; sanitizer aborts do not unwind as C++ exceptions and still surface.
#include <podofo/podofo.h>

#include <cstddef>
#include <cstdint>
#include <vector>

using namespace PoDoFo;

static constexpr size_t kMaxInputSize = 4 * 1024 * 1024;
static constexpr unsigned kMaxPagesWalked = 32;

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

            std::vector<PdfTextEntry> entries;
            page.ExtractTextTo(entries);
            (void)entries;
        }
    }
    catch (const PdfError&)
    {
        // Malformed PDF / unsupported font-program construct -- expected, not a finding.
    }
    catch (const std::exception&)
    {
        // Also an expected rejection path (e.g. a pathological declared length).
    }

    return 0;
}
