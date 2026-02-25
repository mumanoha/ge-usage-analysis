# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0

import os
import datetime
import time
import google.auth
import google.auth.transport.requests
from google.cloud import bigquery
import requests
from flask import Flask

app = Flask(__name__)

@app.route("/", methods=["POST"])
def run_export(request):
    # 1. Identity & Credentials with explicit platform scope
    credentials, project_id = google.auth.default(
        scopes=['https://www.googleapis.com/auth/cloud-platform']
    )
    
    # 2. Force a token refresh
    auth_req = google.auth.transport.requests.Request()
    credentials.refresh(auth_req)

    # 3. Dynamic App Discovery
    location = os.environ.get('LOCATION', 'global')
    engines_url = f"https://discoveryengine.googleapis.com/v1alpha/projects/{project_id}/locations/{location}/collections/default_collection/engines"
    
    engines_resp = requests.get(
        engines_url, 
        headers={"Authorization": f"Bearer {credentials.token}"}
    )
    data = engines_resp.json()

    if "engines" not in data or len(data["engines"]) == 0:
        error_msg = data.get("error", {}).get("message", "No engines found or API error.")
        return f"Error: {error_msg}", 500

    app_id = data["engines"][0]["name"].split("/")[-1]

    # 4. Dynamic Table ID for Retention
    dataset_id = os.environ.get('DATASET_ID')
    timestamp = datetime.datetime.now().strftime("%Y%m%d")
    table_id = f"metrics_export_{timestamp}"

    # 5. Trigger Export (Asynchronous Operation)
    # The API exports the last 30 days of data per call
    export_url = f"https://{location}-discoveryengine.googleapis.com/v1alpha/projects/{project_id}/locations/{location}/collections/default_collection/engines/{app_id}/analytics:exportMetrics"
    payload = {
        "analytics": f"projects/{project_id}/locations/{location}/collections/default_collection/engines/{app_id}",
        "outputConfig": {
            "bigqueryDestination": {
                "datasetId": dataset_id,
                "tableId": table_id
            }
        }
    }
    
    export_resp = requests.post(
        export_url, 
        json=payload, 
        headers={"Authorization": f"Bearer {credentials.token}"}
    )
    print(f"Export job triggered for {table_id}. Response: {export_resp.text}")

    # 6. Wait for Table Creation (Polling Loop)
    client = bigquery.Client(project=project_id, credentials=credentials)
    table_ref = f"{project_id}.{dataset_id}.{table_id}"
    
    table_created = False
    for attempt in range(12):  
        try:
            client.get_table(table_ref)
            print(f"Verified: Table {table_id} exists.")
            table_created = True
            break
        except Exception:
            print(f"Attempt {attempt + 1}: Waiting for table {table_id} to be created...")
            time.sleep(30)

    if not table_created:
        return f"Timeout: Table {table_id} was not created in time.", 504

    # 7. Update Stable View with De-duplicated Gemini Enterprise Schema
    view_id = f"{project_id}.{dataset_id}.latest_metrics"
    view = bigquery.Table(view_id)
    view.view_query = f"""
        SELECT 
            GENERATE_UUID() as id, 
            TO_JSON_STRING(t) as jsonData
        FROM `{project_id}.{dataset_id}.metrics_export_*` AS t
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY date, engine_id, product_type, device_type, agent_name, data_source
            ORDER BY _TABLE_SUFFIX DESC
        ) = 1
    """
    
    client.delete_table(view_id, not_found_ok=True)
    client.create_table(view)

    return {
        "status": "Success",
        "exported_table": table_id,
        "view_schema": "Structured Metadata (De-duplicated)",
        "view_updated": view_id
    }, 200