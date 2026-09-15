# Multi-Invoice Document Splitting

Splitting a single scanned PDF that contains many invoices into one row per invoice,
using Snowflake AI SQL functions. Runs entirely inside Snowflake — no external OCR
service, no document-processing vendor, no data leaving the account.

## The problem

Accounts payable batches arrive as scans, and a scan is rarely one invoice per file. A
typical batch looks like this:

| Page | Document |
|------|----------|
| 1 | Cover sheet listing every invoice in the batch and its balance |
| 2 | Invoice A |
| 3–7 | Signoff sheet, job-site photographs, request email |
| 8 | Invoice B |
| 9–10 | Signoff sheet, request email |
| … | … |

Two obvious approaches both fail:

**Extract from the file as a whole** and you get one row where there should be several.
The totals of separate invoices get merged or one is picked arbitrarily.

**Extract from every page** and you get rows for documents that are not bills.
Supporting documents carry dollar amounts too — a handwritten job work order reading
`TOTAL AMOUNT $5,334.83` is indistinguishable from an invoice total if all you do is
hunt for the largest currency figure on the page.

## The approach

Classify first, then extract. Three steps, three tables.

1. **`SCAN_PAGES`** — `AI_PARSE_DOCUMENT` in `LAYOUT` mode with `page_split`, flattened
   to one row per page. LAYOUT preserves table structure, which matters because both
   the cover sheet and the invoice totals block are tables.

2. **`SCAN_PAGE_TYPES`** — `AI_CLASSIFY` assigns each page one of four labels, and a
   regex independently captures the printed invoice number.

3. **`SCAN_INVOICES`** — payable pages are grouped by invoice number, `AI_EXTRACT`
   pulls the fields, and the amount sign is derived from the document type.

Each step is its own table so that a tuning pass on classification does not re-run the
expensive parse. On a 19-page batch the three steps took roughly 19s, 13s and 3s on an
X-Small warehouse.

## Why only four labels

```
VENDOR_INVOICE   payable, amount positive
CREDIT_MEMO      payable, amount negative
TRANSMITTAL      the cover sheet — carries the batch's expected totals
SUPPORTING       everything else — excluded
```

Photographs, emails, signoff sheets and handwritten work orders all share the
`SUPPORTING` label. They could be told apart, but nothing downstream reads the
difference, and a taxonomy that draws distinctions the pipeline never acts on produces
a misleading accuracy number: misclassifying a photograph as an email counts as an
error while changing nothing about the output.

Every label that remains changes behaviour. On the reference batch, classification was
exact on all 19 pages.

## Notes from a real batch

Three things that shaped the design and are worth knowing before you build something
similar.

**Document parsing hallucinates on photographs.** A dark photograph of parking-lot
light poles returned 751 letters of coherent, entirely invented 19th-century
correspondence. The same page parsed twice produced completely different text. This is
the strongest argument for a classification layer: extract from every page and you will
eventually book a hallucination as an invoice.

**No text-length heuristic separates photographs from documents.** Photo pages ranged
from 2 to 932 characters while a genuine email continuation page returned 17. One photo
page produced more letters than a real signoff sheet. The ordering is inverted, so any
threshold fails in both directions.

**The sign cannot be read off the page.** Credit memos are not printed with a minus
sign — the document simply says "credit memo" and shows a positive figure. So the sign
is derived in SQL from the classified type, never asked of the model:

```sql
CASE WHEN doc_type = 'CREDIT_MEMO'
     THEN -ABS(total_amount) ELSE ABS(total_amount) END AS signed_amount
```

`BOOLOR_AGG` means any page identifying as a credit memo types the whole document as
one, so a multi-page credit memo works the same way.

One extraction detail worth copying: invoices that have been factored carry a
remittance stamp naming the finance company, often printed directly over the totals
block. Without an explicit instruction to ignore it, extraction returns the factor
rather than the vendor and the payee is wrong. The guard is in the `vendor_name` field
description.

## Controls

The notebook ends with three checks worth running on every batch.

| Check | Meaning |
|-------|---------|
| `batch_total` | Should equal the total on the cover sheet. Needs no knowledge of the pipeline, which makes it the strongest available check. |
| `payable_pages_without_number` | Pages classified payable where no invoice number could be read. These are dropped, so non-zero means an invoice is missing. |
| `invoice_number_disagreements` | Regex reading vs. the model's. Independent signals, so disagreement flags a page to look at. |

Extracted rows land as `needs_review` so nothing reaches an ERP without a human
release.

## Running it

Open `unified_scan_invoice_split.ipynb` as a Snowflake Workspace notebook and set the
four parameters in the first code cell:

```python
source_stage    = "@MY_DB.MY_SCHEMA.INVOICE_STAGE"
file_pattern    = "%.pdf"

target_database = "MY_DB"
target_schema   = "MY_SCHEMA"
```

The stage needs a directory table (`DIRECTORY = (ENABLE = TRUE)`) and does not have to
live in the target schema. Then run the notebook top to bottom.

AI function usage is billed per the
[Snowflake Service Consumption Table](https://docs.snowflake.com/en/user-guide/cost-understanding-overall#service-type).
