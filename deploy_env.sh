# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0

#!/bin/bash

# --- 1. PROJECT DETECTION & CONFIGURATION ---
echo "--------------------------------------------------------"
echo "GE Usage Analysis - Interactive Deployment (Cloud Run Service)"
echo "--------------------------------------------------------"

DETECTED_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ -n "$DETECTED_PROJECT" ]; then
    read -p "Detected active project [$DETECTED_PROJECT]. Use this for deployment? (Y/n): " CONFIRM_PROJECT
    CONFIRM_PROJECT=${CONFIRM_PROJECT:-y}
    if [[ "$CONFIRM_PROJECT" =~ ^[Yy]$ ]]; then
        PROJECT_ID=$DETECTED_PROJECT
    else
        read -p "Enter the different GCP Project ID to use: " PROJECT_ID
    fi
else
    read -p "No active project detected. Enter the GCP Project ID: " PROJECT_ID
fi

if [ -z "$PROJECT_ID" ]; then echo "Project ID is required. Exiting."; exit 1; fi

# --- 2. BILLING & PROJECT VERIFICATION ---
RAW_STATUS=$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null)
BILLING_STATUS=${RAW_STATUS,,} 

if [[ "$BILLING_STATUS" != "true" ]]; then
    echo "Billing is NOT enabled for $PROJECT_ID (Current Status: $RAW_STATUS)."
    read -p "Enter Billing Account ID to link (XXXXXX-XXXXXX-XXXXXX): " BILLING_ID
    if [ -n "$BILLING_ID" ]; then
        gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ID"
    else
        echo "Billing ID is required to proceed. Exiting."; exit 1
    fi
else
    echo "Billing is verified as active."
fi

gcloud config set project "$PROJECT_ID" --quiet

# --- 3. RESOURCE NAMING PROMPTS ---
read -p "Enter the GCP Region [us-central1]: " REGION
REGION=${REGION:-us-central1}

read -p "Enter the BigQuery Dataset ID [discovery_analytics_ds]: " DATASET_ID
DATASET_ID=${DATASET_ID:-discovery_analytics_ds}

read -p "Enter the Service Account Name [discovery-export-sa]: " SA_NAME
SA_NAME=${SA_NAME:-discovery-export-sa}

# --- 4. API ENABLEMENT ---
echo "Enabling necessary APIs for Cloud Run Service..."
gcloud services enable \
    discoveryengine.googleapis.com \
    bigquery.googleapis.com \
    run.googleapis.com \
    cloudscheduler.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com

sleep 30

# --- 5. AUTOMATIC BIGQUERY DATASET CREATION ---
if ! bq show --dataset "$PROJECT_ID:$DATASET_ID" &>/dev/null; then
    echo "Creating dataset $DATASET_ID in US multi-region (required for global apps)..."
    bq mk --dataset --location=US "$PROJECT_ID:$DATASET_ID"
else
    echo "Dataset $DATASET_ID already exists."
fi

# --- 6. PERMISSIONS SETUP ---
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
COMPUTE_SA="$PROJECT_NUMBER-compute@developer.gserviceaccount.com"

for ROLE in "roles/storage.admin" "roles/serviceusage.serviceUsageConsumer" "roles/cloudbuild.builds.builder"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$COMPUTE_SA" \
        --role="$ROLE" --quiet
done

# --- 7. CUSTOM APP SERVICE ACCOUNT SETUP ---
SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null; then
    gcloud iam service-accounts create "$SA_NAME" --display-name="Discovery Export SA"
fi

for ROLE in "roles/discoveryengine.admin" "roles/bigquery.admin" "roles/run.invoker"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SA_EMAIL" \
        --role="$ROLE" --quiet
done

# --- 8. CLOUD RUN SERVICE DEPLOYMENT ---
echo "Deploying as a Cloud Run Service with Python 3.12 Runtime..."
SERVICE_NAME="discovery-export"

gcloud run deploy "$SERVICE_NAME" \
    --source=. \
    --region="$REGION" \
    --service-account="$SA_EMAIL" \
    --function=run_export \
    --base-image=python312 \
    --memory=512Mi \
    --cpu=1 \
    --timeout=540s \
    --concurrency=80 \
    --max-instances=1 \
    --ingress=internal \
    --cpu-boost \
    --set-env-vars "DATASET_ID=$DATASET_ID,LOCATION=global" \
    --no-allow-unauthenticated --quiet

# --- 9. DETERMINISTIC SCHEDULER SYNC ---
echo "Configuring daily scheduler job with deterministic URL..."

SERVICE_URL="https://${SERVICE_NAME}-${PROJECT_NUMBER}.${REGION}.run.app"

echo "Targeting Deterministic URL: $SERVICE_URL"

gcloud scheduler jobs create http daily-discovery-export \
    --schedule="0 2 * * *" \
    --uri="$SERVICE_URL" \
    --http-method=POST \
    --oidc-service-account-email="$SA_EMAIL" \
    --oidc-token-audience="$SERVICE_URL" \
    --attempt-deadline=540s \
    --location="$REGION" --quiet 2>/dev/null || \
gcloud scheduler jobs update http daily-discovery-export \
    --uri="$SERVICE_URL" \
    --oidc-token-audience="$SERVICE_URL" \
    --attempt-deadline=540s \
    --location="$REGION" --quiet

echo "--------------------------------------------------------"
echo "DEPLOYMENT SUCCESSFUL"
echo "Project: $PROJECT_ID"
echo "Deterministic URL: $SERVICE_URL"
echo "--------------------------------------------------------"
