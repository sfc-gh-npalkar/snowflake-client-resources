"""
Domain Abuse Detection - Feature Store Setup
Creates entity and feature view for domain risk features.

Usage:
    python setup_feature_store.py --connection <connection_name>

The connection must point to an account that has DOMAIN_RISK_DEMO.BAD_DOMAIN_ML created.
Run the SQL scripts in sql/ first.
"""
import argparse
from snowflake.snowpark import Session
from snowflake.ml.feature_store import FeatureStore, FeatureView, Entity


def get_session(connection_name: str) -> Session:
    return Session.builder.config("connection_name", connection_name).create()


def setup_feature_store(session: Session) -> None:
    session.sql("USE DATABASE DOMAIN_RISK_DEMO").collect()
    session.sql("USE SCHEMA BAD_DOMAIN_ML").collect()
    session.sql("USE WAREHOUSE COMPUTE_WH").collect()

    print("Connected to Snowflake. Setting up Feature Store...")

    fs = FeatureStore(
        session=session,
        database="DOMAIN_RISK_DEMO",
        name="BAD_DOMAIN_ML",
        default_warehouse="COMPUTE_WH",
        creation_mode="CREATE_IF_NOT_EXISTS",
    )

    domain_entity = Entity(name="DOMAIN", join_keys=["DOMAIN_ID"])
    fs.register_entity(domain_entity)
    print("Entity 'DOMAIN' registered.")

    feature_df = session.table("DOMAIN_FEATURES_V").select(
        "DOMAIN_ID",
        "REGISTRATION_DATE",
        "NAME_LENGTH",
        "DIGIT_COUNT",
        "HYPHEN_COUNT",
        "WORD_COUNT",
        "BRAND_KEYWORD_PRESENT",
        "LEETSPEAK_SUBSTITUTION",
        "PHISHING_KEYWORD_PRESENT",
        "SCAM_KEYWORD_PRESENT",
        "DIGIT_RATIO",
        "DOMAINS_BY_REGISTRANT",
        "BULK_REGISTRANT_FLAG",
        "MASS_REGISTRANT_FLAG",
        "WHOIS_PRIVACY_FLAG",
        "NO_CONTENT_FLAG",
        "PRIVACY_NO_CONTENT_COMBO",
        "HIGH_RISK_COUNTRY",
        "ANONYMOUS_EMAIL_FLAG",
        "SUSPICIOUS_NAMESERVER_FLAG",
        "WEBSITE_RISK_SCORE",
    )

    domain_fv = FeatureView(
        name="DOMAIN_RISK_FEATURES",
        entities=[domain_entity],
        feature_df=feature_df,
        timestamp_col="REGISTRATION_DATE",
        refresh_freq="1 hour",
        desc="Domain registration risk features for bad actor detection",
    )

    fs.register_feature_view(feature_view=domain_fv, version="V1", overwrite=True)
    print("FeatureView 'DOMAIN_RISK_FEATURES' V1 registered (backed by Dynamic Table).")
    print("Feature Store setup complete!")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Set up the domain risk Feature Store")
    parser.add_argument("--connection", default="default", help="Snowflake connection name from connections.toml")
    args = parser.parse_args()

    session = get_session(args.connection)
    setup_feature_store(session)
    session.close()
