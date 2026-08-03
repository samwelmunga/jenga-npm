"""
Transformer Fine-Tuning Script
-------------------------------
Fine-tunes a HuggingFace transformer model using config from input/config.yaml.
Copy this template directory and populate input/data/ before running.

Usage:
    python training/main.py
"""

import os
import yaml
import json
from datasets import load_dataset
from transformers import (
    AutoTokenizer,
    AutoModelForSequenceClassification,
    TrainingArguments,
    Trainer,
    DataCollatorWithPadding,
)
import evaluate
import numpy as np


CONFIG_PATH = "input/config.yaml"


def load_config(path: str) -> dict:
    with open(path, "r") as f:
        return yaml.safe_load(f)


def tokenize_dataset(dataset, tokenizer, text_col: str, max_length: int):
    def tokenize(batch):
        return tokenizer(batch[text_col], truncation=True, max_length=max_length)
    return dataset.map(tokenize, batched=True)


def compute_metrics(eval_pred):
    metric = evaluate.load("accuracy")
    logits, labels = eval_pred
    predictions = np.argmax(logits, axis=-1)
    return metric.compute(predictions=predictions, references=labels)


def main():
    config = load_config(CONFIG_PATH)

    model_name = config["model"]["name"]
    data_cfg = config["data"]
    train_cfg = config["training"]
    ckpt_cfg = config.get("checkpoints", {})

    os.makedirs(train_cfg["output_dir"], exist_ok=True)
    os.makedirs(train_cfg["logging_dir"], exist_ok=True)
    os.makedirs(ckpt_cfg.get("dir", "checkpoints/"), exist_ok=True)

    print(f"Loading tokenizer and model: {model_name}")
    tokenizer = AutoTokenizer.from_pretrained(model_name)

    dataset = load_dataset(
        "json",
        data_files={
            "train": data_cfg["train_file"],
            "eval": data_cfg["eval_file"],
        },
    )

    label_list = sorted(set(dataset["train"][data_cfg["label_column"]]))
    label2id = {l: i for i, l in enumerate(label_list)}
    id2label = {i: l for l, i in label2id.items()}

    def encode_labels(batch):
        batch[data_cfg["label_column"]] = [label2id[l] for l in batch[data_cfg["label_column"]]]
        return batch

    dataset = dataset.map(encode_labels, batched=True)
    dataset = dataset.rename_column(data_cfg["label_column"], "labels")
    dataset = tokenize_dataset(dataset, tokenizer, data_cfg["text_column"], data_cfg["max_length"])
    dataset.set_format("torch", columns=["input_ids", "attention_mask", "labels"])

    model = AutoModelForSequenceClassification.from_pretrained(
        model_name,
        num_labels=len(label_list),
        id2label=id2label,
        label2id=label2id,
    )

    training_args = TrainingArguments(
        output_dir=ckpt_cfg.get("dir", "checkpoints/"),
        num_train_epochs=train_cfg["num_train_epochs"],
        per_device_train_batch_size=train_cfg["per_device_train_batch_size"],
        per_device_eval_batch_size=train_cfg["per_device_eval_batch_size"],
        learning_rate=train_cfg["learning_rate"],
        warmup_steps=train_cfg["warmup_steps"],
        weight_decay=train_cfg["weight_decay"],
        logging_dir=train_cfg["logging_dir"],
        evaluation_strategy=train_cfg["evaluation_strategy"],
        save_strategy=train_cfg["save_strategy"],
        load_best_model_at_end=train_cfg["load_best_model_at_end"],
        save_total_limit=ckpt_cfg.get("save_total_limit", 3),
    )

    data_collator = DataCollatorWithPadding(tokenizer=tokenizer)

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=dataset["train"],
        eval_dataset=dataset["eval"],
        tokenizer=tokenizer,
        data_collator=data_collator,
        compute_metrics=compute_metrics,
    )

    print("Starting training...")
    trainer.train()

    print(f"Saving fine-tuned model to {train_cfg['output_dir']}")
    trainer.save_model(train_cfg["output_dir"])
    tokenizer.save_pretrained(train_cfg["output_dir"])

    results = trainer.evaluate()
    results_path = os.path.join(train_cfg["logging_dir"], "eval_results.json")
    with open(results_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"Evaluation results saved to {results_path}")


if __name__ == "__main__":
    main()
