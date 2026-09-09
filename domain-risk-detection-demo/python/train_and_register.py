"""
Domain Abuse Detection - Train sklearn model and register in Model Registry.
Shows the MLOps governance story: train, evaluate, version, register.

Usage:
    python train_and_register.py --connection <connection_name>

Run sql/04_train_model.sql first to create the SNOWFLAKE.ML.CLASSIFICATION model,
then run this script to also register a GradientBoosting model in the Model Registry.
"""
import argparse
import pandas as pd
from snowflake.snowpark import Session
from snowflake.ml.registry import Registry
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report


def get_session(connection_name: str) -> Session:
    return Session.builder.config("connection_name", connection_name).create()


def train_and_register(session: Session) -> None:
    session.sql("USE DATABASE DOMAIN_RISK_DEMO").collect()
    session.sql("USE SCHEMA BAD_DOMAIN_ML").collect()
    session.sql("USE WAREHOUSE COMPUTE_WH").collect()

    print("Loading training data from Feature Store...")
    df = session.table("TRAINING_FEATURES").to_pandas()
    print(f"  Rows: {len(df)}, Features: {df.shape[1] - 1}")

    X = df.drop("IS_SUSPICIOUS", axis=1)
    y = df["IS_SUSPICIOUS"].astype(int)

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )

    print("\nTraining GradientBoostingClassifier...")
    model = GradientBoostingClassifier(
        n_estimators=200, max_depth=5, learning_rate=0.1, random_state=42
    )
    model.fit(X_train, y_train)

    y_pred = model.predict(X_test)
    print("\n=== Model Performance ===")
    print(classification_report(y_test, y_pred, target_names=["Legitimate", "Suspicious"]))

    print("Registering model in Snowflake Model Registry...")
    reg = Registry(session=session, database_name="DOMAIN_RISK_DEMO", schema_name="BAD_DOMAIN_ML")

    precision = float(y_pred[y_test == 1].sum()) / max(float(y_pred.sum()), 1)
    recall = float(y_pred[y_test == 1].sum()) / max(float((y_test == 1).sum()), 1)
    accuracy = float((y_pred == y_test).sum()) / len(y_test)

    reg.log_model(
        model_name="BAD_DOMAIN_CLASSIFIER_GBM",
        version_name="V1",
        model=model,
        sample_input_data=X_test.head(10),
        comment=(
            "GradientBoosting classifier for domain abuse detection. "
            "Features: domain name patterns, registrant behavior, WHOIS/content signals."
        ),
        metrics={
            "precision_suspicious": precision,
            "recall_suspicious": recall,
            "accuracy": accuracy,
        },
    )

    print("Model registered: DOMAIN_RISK_DEMO.BAD_DOMAIN_ML.BAD_DOMAIN_CLASSIFIER_GBM V1")
    print("Model Registry setup complete!")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train and register the domain abuse detection model")
    parser.add_argument("--connection", default="default", help="Snowflake connection name from connections.toml")
    args = parser.parse_args()

    session = get_session(args.connection)
    train_and_register(session)
    session.close()
