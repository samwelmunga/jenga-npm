"""
Classifier Training Script
--------------------------
Trains a sklearn-compatible or XGBoost classifier using config from input/config.yaml.
Copy this template directory and populate input/data/ before running.

Usage:
    python training/main.py
"""

import os
import yaml
import joblib
import json
import pandas as pd
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.metrics import classification_report, accuracy_score
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from sklearn.svm import SVC
from sklearn.linear_model import LogisticRegression


CONFIG_PATH = "input/config.yaml"


def load_config(path: str) -> dict:
    with open(path, "r") as f:
        return yaml.safe_load(f)


def build_model(config: dict):
    model_type = config["model"]["type"]
    params = config["model"].get("params", {})

    models = {
        "random_forest": RandomForestClassifier,
        "gradient_boosting": GradientBoostingClassifier,
        "svm": SVC,
        "logistic_regression": LogisticRegression,
    }

    try:
        import xgboost as xgb
        models["xgboost"] = xgb.XGBClassifier
    except ImportError:
        pass

    if model_type not in models:
        raise ValueError(f"Unsupported model type: {model_type}. Choose from {list(models.keys())}")

    return models[model_type](**params)


def main():
    config = load_config(CONFIG_PATH)

    os.makedirs(config["output"]["results_dir"], exist_ok=True)
    os.makedirs(config["output"]["models_dir"], exist_ok=True)

    print("Loading data...")
    df_train = pd.read_csv(config["data"]["train_file"])
    target = config["data"]["target_column"]
    X = df_train.drop(columns=[target])
    y = df_train[target]

    model = build_model(config)

    if config["training"].get("cross_validation"):
        folds = config["training"].get("cv_folds", 5)
        print(f"Running {folds}-fold cross-validation...")
        cv_scores = cross_val_score(model, X, y, cv=folds)
        print(f"CV Accuracy: {cv_scores.mean():.4f} (+/- {cv_scores.std():.4f})")

    test_size = config["data"].get("test_size", 0.2)
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=test_size, random_state=42)

    print("Training model...")
    model.fit(X_train, y_train)

    print("Evaluating...")
    y_pred = model.predict(X_test)
    report = classification_report(y_pred, y_test, output_dict=True)
    accuracy = accuracy_score(y_test, y_pred)
    print(f"Accuracy: {accuracy:.4f}")

    results_path = os.path.join(config["output"]["results_dir"], "results.json")
    with open(results_path, "w") as f:
        json.dump({"accuracy": accuracy, "classification_report": report}, f, indent=2)
    print(f"Results saved to {results_path}")

    model_path = os.path.join(config["output"]["models_dir"], config["output"]["model_filename"])
    joblib.dump(model, model_path)
    print(f"Model saved to {model_path}")


if __name__ == "__main__":
    main()
