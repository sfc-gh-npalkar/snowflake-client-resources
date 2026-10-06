DEFINE PROCEDURE {{ db }}.RAW.LOAD_CONTACTS()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'phonenumbers==9.0.36')
HANDLER = 'run'
AS
$$
import phonenumbers
from datetime import datetime

# Stands in for an API response, so the demo needs no token.
CONTACTS = [
    ("101", "Priya Thibodeaux", "(334) 555-0142"),
    ("102", "Yusuf Brennan", "334.555.0199"),
    ("103", "Emeka Whitlock", "+1 334 555 0123"),
    ("104", "Marisol Okafor", "call me"),
]

def to_e164(raw):
    try:
        num = phonenumbers.parse(raw, "US")
    except phonenumbers.NumberParseException:
        return None
    if phonenumbers.is_possible_number_with_reason(num) != phonenumbers.ValidationResult.IS_POSSIBLE:
        return None
    return phonenumbers.format_number(num, phonenumbers.PhoneNumberFormat.E164)

def run(session):
    now = datetime.utcnow()
    rows = [(cid, name, raw, to_e164(raw), now) for cid, name, raw in CONTACTS]
    session.sql("TRUNCATE TABLE {{ db }}.RAW.CONTACTS").collect()
    session.create_dataframe(
        rows, schema=["CONTACT_ID", "FULL_NAME", "PHONE_RAW", "PHONE_E164", "LOADED_AT"]
    ).write.mode("append").save_as_table("{{ db }}.RAW.CONTACTS")
    return f"loaded {len(rows)} contacts"
$$;
