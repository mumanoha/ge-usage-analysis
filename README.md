# Gemini Enterprise (GE) Usage Analysis Export

This solution automates the daily export of Gemini Enterprise metrics from Discovery Engine to BigQuery. It utilizes a Cloud Run service triggered by Cloud Scheduler to manage asynchronous exports and creates a de-duplicated view for stable analytics reporting.

## 📋 Prerequisites & Operational Constraints

* **API Quotas**: The `analytics:exportMetrics` method is limited to **5 calls per day** per project and **25 calls per day** per organization.
* **Data Availability**: Metrics are refreshed approximately every **6 hours**. It may take several hours after app creation for data to appear.
* **Retention**: Each export call retrieves metrics for the **past 30 days**, including the current day.
* **IAM Roles**: The deploying identity or Service Account requires:
  * `roles/discoveryengine.viewer` (to call the export API).
  * `roles/bigquery.dataEditor` and `roles/bigquery.jobUser` (to create datasets and tables).



## 🏗️ Architecture & Configuration

* **Runtime**: Python 3.12 (Ubuntu 22 Full).
* **Compute**: Cloud Run (Function-style) with 512Mi Memory and 1 CPU.
* **Location Mapping**: BigQuery datasets **must** match the Gemini Enterprise app location. For **global** apps, the dataset **must** be in the **US** multi-region.

## 🚀 Deployment

### 1. Repository Setup

```bash
git clone https://github.com/mumanoha/ge-usage-analysis.git
cd ge-usage-analysis

```

### 2. Automated Deployment

The `deploy_burns_env.sh` script automates API enablement and service deployment:

```bash
chmod +x deploy_env.sh
./deploy_env.sh

```

## 🧪 Testing & Operation Status

### How to Force Run the Export

To verify the deployment immediately without waiting for the daily schedule, trigger the Cloud Scheduler job manually:

**Option A: Using the Cloud Console**

1. Go to the **Cloud Scheduler** page.
2. Find `daily-discovery-export` and click **Force Run**.
3. Refresh after 60 seconds; the status should show **Success**.

**Option B: Using gcloud CLI**

```bash
gcloud scheduler jobs run daily-discovery-export --location=us-central1

```

## 🛠️ Troubleshooting

| Symptom | Root Cause | Resolution |
| --- | --- | --- |
| **Error Code 3** | BigQuery dataset not found in the expected location. | Ensure the dataset is in **US** for global apps or **EU** for EU apps. |
| **504/Timeout** | The polling loop or Scheduler timed out before the LRO finished. | Ensure both Cloud Run and Scheduler timeouts are set to **540s**. |
| **Quota Exhausted** | More than 5 export calls were made in 24 hours. | Wait 24 hours or use a separate project for testing. |
| **Missing Metrics** | Data store unlinked or CMEK encryption issues. | Verify the data store is linked; metrics are only available from the time of linking. |

---

*Copyright 2026 Google LLC. Licensed under the Apache License, Version 2.0.*

---
