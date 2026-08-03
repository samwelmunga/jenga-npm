# Relatable Classification Dataset — Student Exam Outcome

## What it is
A classification dataset uses real-world, named features to represent observations, and a `label` column to indicate the class each observation belongs to. Rather than `feature1`, `feature2`, `feature3`, relatable datasets use domain-meaningful names that make the data immediately interpretable.

## Why it exists
Generic placeholder names obscure what the model is actually learning. Naming features after real concepts (e.g. `study_hours`, `sleep_hours`, `practice_tests`) makes it easy to:
- Reason about why a prediction was made
- Spot data quality issues
- Communicate results to non-technical stakeholders

## How it works
Each row in the CSV is one observation. The model learns the relationship between the feature columns and the `label` (0 = failed, 1 = passed). During training, a logistic regression (or other classifier) fits a decision boundary through the feature space.

## When to use it
Use a relatable dataset when:
- Prototyping a classifier and want fast sanity-checking
- Explaining ML concepts to others
- The domain is well understood and features map cleanly to real measurements

Avoid when:
- You need a statistically rigorous benchmark — use a real dataset (e.g. UCI repository)
- Features are truly abstract (e.g. latent embeddings)

## Example — Student Exam Outcome Classifier

### Dataset (`data/train.csv`)

```csv
study_hours,sleep_hours,practice_tests,label
7.5,8,4,1
2.0,5,0,0
5.0,7,2,1
1.5,4,0,0
8.0,9,5,1
3.0,6,1,0
6.5,8,3,1
1.0,3,0,0
4.5,7,2,1
2.5,5,1,0
9.0,8,6,1
0.5,4,0,0
6.0,7,3,1
3.5,6,1,0
7.0,9,4,1
2.0,4,0,0
5.5,7,2,1
1.5,5,1,0
8.5,8,5,1
4.0,6,2,1
```

**Features:**
| Column | Meaning |
|---|---|
| `study_hours` | Hours the student studied before the exam |
| `sleep_hours` | Hours of sleep the night before |
| `practice_tests` | Number of practice tests completed |
| `label` | `1` = passed, `0` = failed |

### Training run output

```
[pre-flight] Running validate.py in jobs/roxana-cls...
✅ Validation passed: data/train.csv is valid.

[smoke test] Running train.py --smoke in jobs/roxana-cls...
✅ Training smoke_complete. Results written to jobs/roxana-cls/results.json
```

### What the model learns
Students who studied more hours, slept well, and completed more practice tests are predicted to pass. The logistic regression draws a boundary in 3D feature space (study_hours × sleep_hours × practice_tests) separating the two classes.

### Key insight
Even with only 20 rows, the pattern is clear enough for the model to separate the classes. In production you'd use hundreds or thousands of rows and validate with cross-validation metrics.
