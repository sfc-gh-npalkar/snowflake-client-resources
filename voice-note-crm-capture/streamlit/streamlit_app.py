"""Voice-note capture: upload a dictation, review what Snowflake extracted, approve, send to the CRM.

Runs in Streamlit in Snowflake (uses the app's session) or locally (uses st.connection).
"""
import io
import os
from datetime import datetime

import streamlit as st

DB = "VOICE_CAPTURE.PIPELINE"
STAGE = f"@{DB}.VOICE_STAGE"

st.set_page_config(page_title="Voice notes", page_icon=":microphone:", layout="wide")


@st.cache_resource
def get_session():
    try:
        from snowflake.snowpark.context import get_active_session
        return get_active_session()
    except Exception:
        conn = st.connection(
            "snowflake",
            connection_name=os.getenv("SNOWFLAKE_DEFAULT_CONNECTION_NAME") or "default",
        )
        return conn.session()


session = get_session()
tab_capture, tab_review = st.tabs(["1. Capture", "2. Review & approve"])

with tab_capture:
    st.caption("Dictate after a visit. Snowflake transcribes it and pulls out the CRM fields.")
    associate_id = st.text_input("Associate ID", help="Your CRM associate ID; it becomes the filename prefix.")
    uploaded = st.file_uploader("Voice memo", type=["m4a", "mp3", "wav", "aac", "ogg", "webm", "flac"])
    recorded = st.audio_input("...or record now") if hasattr(st, "audio_input") else None
    audio = uploaded or recorded
    if audio is not None:
        st.audio(audio)
    if st.button("Submit", type="primary", disabled=not (audio and associate_id.strip())):
        ext = os.path.splitext(getattr(audio, "name", "") or "")[1] or ".wav"
        safe_id = "".join(ch for ch in associate_id.strip() if ch.isalnum() or ch == "-")
        file_name = f"{safe_id}_{datetime.now():%Y%m%d_%H%M%S}{ext}"
        session.file.put_stream(io.BytesIO(audio.getvalue()), f"{STAGE}/{file_name}",
                                auto_compress=False, overwrite=True)
        session.sql(f"ALTER STAGE {STAGE[1:]} REFRESH").collect()
        st.success(f"Submitted {file_name}. It appears under Review in about two minutes.")

with tab_review:
    if st.button("Refresh"):
        st.rerun()
    queue = session.sql(f"""
        SELECT q.file_path, q.prospect_id, q.match_type, q.field, q.old_value, q.new_value,
               q.rule, q.needs_review, r.transcript
        FROM {DB}.PENDING_UPDATES q JOIN {DB}.VOICE_NOTES_RAW r USING (file_path)
        WHERE q.decision = 'PENDING'
        ORDER BY q.file_path, q.needs_review DESC, q.field""").to_pandas()

    if queue.empty:
        st.info("Nothing waiting for review.")
    for file_path, note in queue.groupby("FILE_PATH", sort=False):
        flagged = int(note["NEEDS_REVIEW"].sum())
        label = f"{file_path} - prospect {note['PROSPECT_ID'].iloc[0] or 'NEW'} - {flagged} flagged"
        with st.expander(label, expanded=flagged > 0):
            st.caption(note["TRANSCRIPT"].iloc[0])
            edited = st.data_editor(
                note.assign(APPROVE=~note["NEEDS_REVIEW"])[
                    ["APPROVE", "FIELD", "OLD_VALUE", "NEW_VALUE", "RULE", "MATCH_TYPE"]],
                hide_index=True, disabled=["FIELD", "OLD_VALUE", "NEW_VALUE", "RULE", "MATCH_TYPE"],
                key=f"ed_{file_path}")
            if st.button("Save decisions", key=f"save_{file_path}"):
                for _, row in edited.iterrows():
                    session.sql(f"""UPDATE {DB}.PENDING_UPDATES
                        SET decision = ?, decided_by = CURRENT_USER(), decided_at = CURRENT_TIMESTAMP()
                        WHERE file_path = ? AND field = ? AND decision = 'PENDING'""",
                        params=["APPROVED" if row["APPROVE"] else "REJECTED", file_path, row["FIELD"]]).collect()
                st.success("Saved.")

    st.divider()
    if st.button("Send decisions to CRM", type="primary"):
        result = session.sql(f"CALL {DB}.WRITE_BACK(FALSE)").collect()[0][0]
        st.success(result)
