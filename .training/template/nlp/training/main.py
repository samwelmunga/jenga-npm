"""
NLP Pipeline Training Script
-----------------------------
Trains an NLP model/pipeline (NER, classification, POS, etc.)
using config from input/config.yaml.
Copy this template directory and populate input/data/ before running.

Usage:
    python training/main.py
"""

import os
import yaml
import json
import spacy
from spacy.tokens import DocBin
from spacy.training import Example
from spacy.util import minibatch, compounding
import random


CONFIG_PATH = "input/config.yaml"


def load_config(path: str) -> dict:
    with open(path, "r") as f:
        return yaml.safe_load(f)


def load_data(filepath: str, nlp):
    doc_bin = DocBin().from_disk(filepath)
    return list(doc_bin.get_docs(nlp.vocab))


def evaluate_model(nlp, eval_docs: list) -> dict:
    examples = [Example(nlp(doc.text), doc) for doc in eval_docs]
    scores = nlp.evaluate(examples)
    return scores


def main():
    config = load_config(CONFIG_PATH)

    model_name = config["model"]["name"]
    task = config["model"]["task"]
    data_cfg = config["data"]
    train_cfg = config["training"]
    ckpt_cfg = config.get("checkpoints", {})
    output_cfg = config["output"]

    os.makedirs(output_cfg["results_dir"], exist_ok=True)
    os.makedirs(output_cfg["models_dir"], exist_ok=True)
    os.makedirs(ckpt_cfg.get("dir", "checkpoints/"), exist_ok=True)

    print(f"Loading base model: {model_name}")
    try:
        nlp = spacy.load(model_name)
    except OSError:
        print(f"Model '{model_name}' not found locally. Run: python -m spacy download {model_name}")
        raise

    print("Loading training data...")
    train_docs = load_data(data_cfg["train_file"], nlp)
    eval_docs = load_data(data_cfg["eval_file"], nlp)

    train_examples = [Example(nlp.make_doc(doc.text), doc) for doc in train_docs]

    # Disable unrelated pipeline components during training
    pipe_exceptions = [task, "tok2vec"]
    unaffected_pipes = [p for p in nlp.pipe_names if p not in pipe_exceptions]

    n_iter = train_cfg["n_iter"]
    dropout = train_cfg.get("dropout", 0.2)
    save_every = ckpt_cfg.get("save_every_n_iter", 10)
    ckpt_dir = ckpt_cfg.get("dir", "checkpoints/")
    all_results = []

    print(f"Training for {n_iter} iterations...")
    with nlp.disable_pipes(*unaffected_pipes):
        optimizer = nlp.resume_training()
        optimizer.learn_rate = train_cfg.get("learning_rate", 1e-3)

        for i in range(n_iter):
            random.shuffle(train_examples)
            losses = {}
            batches = minibatch(train_examples, size=compounding(4.0, train_cfg["batch_size"], 1.001))
            for batch in batches:
                nlp.update(batch, drop=dropout, losses=losses, sgd=optimizer)

            scores = evaluate_model(nlp, eval_docs)
            print(f"Iter {i+1}/{n_iter} — Losses: {losses} | Scores: {scores}")
            all_results.append({"iter": i + 1, "losses": losses, "scores": scores})

            if (i + 1) % save_every == 0:
                ckpt_path = os.path.join(ckpt_dir, f"checkpoint_iter_{i+1}")
                nlp.to_disk(ckpt_path)
                print(f"  Checkpoint saved to {ckpt_path}")

    model_path = output_cfg["models_dir"]
    nlp.to_disk(model_path)
    print(f"Model saved to {model_path}")

    results_path = os.path.join(output_cfg["results_dir"], "results.json")
    with open(results_path, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"Results saved to {results_path}")


if __name__ == "__main__":
    main()
