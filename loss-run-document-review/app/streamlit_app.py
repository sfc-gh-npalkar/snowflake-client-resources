"""Loss-run review: source page on the left, extracted values on the right."""
import io

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

DB = "LOSS_RUN_DEMO.PIPELINE"
STAGE = f"@{DB}.DOCS"

st.set_page_config(page_title="Loss Run Review", layout="wide")
session = get_active_session()


def q(sql, params=None):
    return session.sql(sql, params=params).to_pandas()


@st.cache_data(show_spinner=False)
def page_image(file_path: str, page_index: int):
    """Render one PDF page to PNG. Returns None if the renderer is unavailable."""
    try:
        import pypdfium2 as pdfium
    except ImportError:
        return None
    data = session.file.get_stream(f"{STAGE}/{file_path}").read()
    page = pdfium.PdfDocument(data)[page_index]
    buf = io.BytesIO()
    page.render(scale=1.6).to_pil().save(buf, format="PNG")
    return buf.getvalue()


def save_override(file_path, target, line_number, field, original, corrected):
    session.sql(
        f"INSERT INTO {DB}.EXTRACTION_OVERRIDES "
        "(FILE_PATH, TARGET, LINE_NUMBER, FIELD_NAME, ORIGINAL_VALUE, CORRECTED_VALUE) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        params=[file_path, target, line_number, field, original, corrected],
    ).collect()


st.title("Loss Run Review")

gate = q(f"SELECT * FROM {DB}.DOCUMENT_GATE ORDER BY STATUS DESC, FILE_PATH")
c1, c2, c3 = st.columns(3)
c1.metric("Loss runs", len(gate))
c2.metric("Needs review", int((gate["STATUS"] == "NEEDS_REVIEW").sum()))
c3.metric("Approved", int(gate["STATUS"].isin(["APPROVED", "AUTO_APPROVED"]).sum()))

doc = st.selectbox(
    "Document",
    gate["FILE_PATH"],
    format_func=lambda f: f"{f}  ·  {gate.loc[gate.FILE_PATH == f, 'STATUS'].iat[0]}",
)
g = gate[gate.FILE_PATH == doc].iloc[0]

reasons = g["GATE_REASONS"]
if reasons and reasons != "[]":
    st.warning("Why this needs review: " + ", ".join(pd.read_json(io.StringIO(reasons), typ="series")))

lines = q(f"SELECT * FROM {DB}.LOSS_RUN_LINES_CURRENT WHERE FILE_PATH = ? ORDER BY LINE_NUMBER", [doc])
pages = q(f"SELECT PAGE_INDEX, PAGE_CONTENT, PAGE_COUNT FROM {DB}.DOCUMENT_PAGES WHERE FILE_PATH = ? ORDER BY PAGE_INDEX", [doc])

left, right = st.columns([1, 1])

with right:
    st.subheader("Header fields")
    hdr = q(
        f"SELECT FIELD_NAME, FIELD_VALUE, EXTRACTED_VALUE, ROUND(SCORE, 2) AS SCORE, NEEDS_REVIEW, CORRECTED "
        f"FROM {DB}.HEADER_FIELDS_CURRENT WHERE FILE_PATH = ? ORDER BY FIELD_NAME",
        [doc],
    )
    st.dataframe(
        hdr.style.apply(
            lambda r: ["background-color: #fff3cd" if r.NEEDS_REVIEW else ""] * len(r), axis=1
        ),
        hide_index=True,
        use_container_width=True,
    )
    with st.form("fix_header"):
        f1, f2 = st.columns([1, 2])
        field = f1.selectbox("Field", hdr["FIELD_NAME"])
        value = f2.text_input("Corrected value")
        if st.form_submit_button("Save header correction") and value:
            orig = hdr.loc[hdr.FIELD_NAME == field, "EXTRACTED_VALUE"].iat[0]
            save_override(doc, "HEADER", None, field, orig, value)
            st.rerun()

    st.subheader("Claim lines")
    show_flagged = st.toggle("Flagged lines only", value=False)
    view = lines.copy()
    view["FLAGS"] = view["ROW_FLAGS"].fillna("[]").str.strip("[]").str.replace('"', "")
    if show_flagged:
        view = view[view["FLAGS"] != ""]
    st.dataframe(
        view[["LINE_NUMBER", "PAGE_INDEX", "CLAIM_NUMBER", "LOSS_DATE", "STATUS", "COVERAGE",
              "PAID", "RESERVE", "EXPENSE", "INCURRED_CALC", "FLAGS"]],
        hide_index=True,
        use_container_width=True,
        height=320,
    )
    with st.form("fix_line"):
        l1, l2, l3 = st.columns([1, 1, 2])
        line_no = l1.selectbox("Line", lines["LINE_NUMBER"])
        lfield = l2.selectbox("Field", ["paid", "reserve", "expense", "status", "claim_number"])
        lval = l3.text_input("Corrected value ")
        if st.form_submit_button("Save line correction") and lval:
            row = lines[lines.LINE_NUMBER == line_no].iloc[0]
            raw = {"paid": "PAID_RAW", "reserve": "RESERVE_RAW", "expense": "EXPENSE_RAW",
                   "status": "STATUS", "claim_number": "CLAIM_NUMBER"}[lfield]
            save_override(doc, "LINE", int(line_no), lfield, str(row[raw]), lval)
            st.rerun()

    st.subheader("Decision")
    note = st.text_input("Note")
    a, r = st.columns(2)
    for col, decision in ((a, "APPROVED"), (r, "REJECTED")):
        if col.button(decision.title(), use_container_width=True):
            session.sql(
                f"INSERT INTO {DB}.DOCUMENT_REVIEWS (FILE_PATH, DECISION, NOTE) VALUES (?, ?, ?)",
                params=[doc, decision, note],
            ).collect()
            st.rerun()

with left:
    st.subheader("Source page")
    linked = sorted(lines["PAGE_INDEX"].dropna().astype(int).unique().tolist())
    default = linked[0] if linked else 0
    page_index = st.number_input(
        f"Page (0–{int(pages.PAGE_COUNT.max()) - 1})  ·  claim pages: {linked}",
        min_value=0, max_value=int(pages.PAGE_COUNT.max()) - 1, value=default,
    )
    img = page_image(doc, int(page_index))
    if img:
        st.image(img, use_container_width=True)
    else:
        st.caption("Page image unavailable; showing parsed page text.")
        st.markdown(pages.loc[pages.PAGE_INDEX == page_index, "PAGE_CONTENT"].iat[0])
