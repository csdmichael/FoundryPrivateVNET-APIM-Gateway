"""Create Azure AI Search indexes and Cosmos DB-backed indexers for local use cases."""

import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config

from azure.core.credentials import AzureKeyCredential
from azure.search.documents.indexes import SearchIndexClient, SearchIndexerClient
from azure.search.documents.indexes.models import (
    FieldMapping,
    IndexingSchedule,
    SearchFieldDataType,
    SearchIndex,
    SearchIndexer,
    SearchIndexerDataContainer,
    SearchIndexerDataSourceConnection,
    SearchableField,
    SemanticConfiguration,
    SemanticField,
    SemanticPrioritizedFields,
    SemanticSearch,
    SimpleField,
)


USE_CASE = config.get_use_case()
AZURE_RESOURCES = config.azure_resources()
DOCUMENT_SETTINGS = config.document_config()["use_cases"][USE_CASE]
SEARCH_ASSETS = config.use_case_settings(USE_CASE)["search_assets"]

SEARCH_ENDPOINT = AZURE_RESOURCES["search"]["target_endpoint"].rstrip("/")
INDEX_NAME = SEARCH_ASSETS["index"]
INDEXER_NAME = SEARCH_ASSETS["indexer"]
DATA_SOURCE_NAME = SEARCH_ASSETS["data_source"]
SEMANTIC_CONFIG_NAME = f"{INDEX_NAME}-semantic"

COSMOSDB_DATABASE = AZURE_RESOURCES["cosmosdb"]["database_name"]
COSMOSDB_CONTAINER = AZURE_RESOURCES["cosmosdb"]["container_name"]
COSMOSDB_RESOURCE_ID = AZURE_RESOURCES["cosmosdb"]["resource_id"]

SEARCH_KEY = os.environ["AZURE_AI_SEARCH_KEY"]

file_format = str(DOCUMENT_SETTINGS.get("file_format", "")).lower()
if file_format.startswith("ppt"):
    extension_filter = "ppt"
else:
    extension_filter = file_format

INDEXER_QUERY = (
    f"SELECT * FROM c WHERE CONTAINS(LOWER(c.fileName), '.{extension_filter}')"
)


def create_index(index_client: SearchIndexClient) -> None:
    fields = [
        SimpleField(name="id", type=SearchFieldDataType.String, key=True, filterable=True),
        SearchableField(name="content", type=SearchFieldDataType.String, analyzer_name="en.microsoft"),
        SearchableField(name="fileName", type=SearchFieldDataType.String, filterable=True, sortable=True),
        SearchableField(name="title", type=SearchFieldDataType.String),
        SimpleField(name="state", type=SearchFieldDataType.String, filterable=True, facetable=True),
        SearchableField(name="stateName", type=SearchFieldDataType.String, filterable=True, facetable=True),
        SimpleField(name="status", type=SearchFieldDataType.String, filterable=True),
        SimpleField(name="overallConfidence", type=SearchFieldDataType.Double, filterable=True, sortable=True),
        SimpleField(name="confidenceCategory", type=SearchFieldDataType.String, filterable=True, facetable=True),
        SearchableField(name="confidenceLabel", type=SearchFieldDataType.String),
        SimpleField(name="totalFields", type=SearchFieldDataType.Int32, filterable=True),
        SimpleField(name="totalSections", type=SearchFieldDataType.Int32, filterable=True),
        SimpleField(name="uploadedAt", type=SearchFieldDataType.DateTimeOffset, filterable=True, sortable=True),
        SimpleField(name="parsedAt", type=SearchFieldDataType.DateTimeOffset, filterable=True, sortable=True),
    ]

    semantic_search = SemanticSearch(
        configurations=[
            SemanticConfiguration(
                name=SEMANTIC_CONFIG_NAME,
                prioritized_fields=SemanticPrioritizedFields(
                    content_fields=[SemanticField(field_name="content")],
                    title_field=SemanticField(field_name="fileName"),
                    keywords_fields=[
                        SemanticField(field_name="stateName"),
                        SemanticField(field_name="confidenceLabel"),
                    ],
                ),
            )
        ]
    )

    index = SearchIndex(name=INDEX_NAME, fields=fields, semantic_search=semantic_search)
    result = index_client.create_or_update_index(index)
    print(f"Created/updated index: {result.name}")


def create_data_source(indexer_client: SearchIndexerClient) -> None:
    connection_string = (
        f"ResourceId={COSMOSDB_RESOURCE_ID};"
        f"Database={COSMOSDB_DATABASE};"
        "IdentityAuthType=AccessToken;"
    )
    data_source = SearchIndexerDataSourceConnection(
        name=DATA_SOURCE_NAME,
        type="cosmosdb",
        connection_string=connection_string,
        container=SearchIndexerDataContainer(name=COSMOSDB_CONTAINER, query=INDEXER_QUERY),
    )
    result = indexer_client.create_or_update_data_source_connection(data_source)
    print(f"Created/updated data source: {result.name}")
    print("  Type: cosmosdb")
    print(f"  Database: {COSMOSDB_DATABASE}")
    print(f"  Container: {COSMOSDB_CONTAINER}")
    print(f"  Query filter: {INDEXER_QUERY}")


def create_indexer(indexer_client: SearchIndexerClient) -> None:
    schedule = IndexingSchedule(interval="P1D", start_time=datetime(2024, 1, 1, 16, 0, tzinfo=timezone.utc))
    mappings = [
        FieldMapping(source_field_name="id", target_field_name="id"),
        FieldMapping(source_field_name="content", target_field_name="content"),
        FieldMapping(source_field_name="fileName", target_field_name="fileName"),
        FieldMapping(source_field_name="title", target_field_name="title"),
        FieldMapping(source_field_name="state", target_field_name="state"),
        FieldMapping(source_field_name="stateName", target_field_name="stateName"),
        FieldMapping(source_field_name="status", target_field_name="status"),
        FieldMapping(source_field_name="overallConfidence", target_field_name="overallConfidence"),
        FieldMapping(source_field_name="confidenceCategory", target_field_name="confidenceCategory"),
        FieldMapping(source_field_name="confidenceLabel", target_field_name="confidenceLabel"),
        FieldMapping(source_field_name="totalFields", target_field_name="totalFields"),
        FieldMapping(source_field_name="totalSections", target_field_name="totalSections"),
        FieldMapping(source_field_name="uploadedAt", target_field_name="uploadedAt"),
        FieldMapping(source_field_name="parsedAt", target_field_name="parsedAt"),
    ]
    indexer = SearchIndexer(
        name=INDEXER_NAME,
        data_source_name=DATA_SOURCE_NAME,
        target_index_name=INDEX_NAME,
        schedule=schedule,
        field_mappings=mappings,
    )
    result = indexer_client.create_or_update_indexer(indexer)
    print(f"Created/updated indexer: {result.name}")
    print("  Schedule: Daily at 8:00 AM PST (16:00 UTC)")
    print(f"  Data source: {DATA_SOURCE_NAME}")
    print(f"  Target index: {INDEX_NAME}")


def main() -> None:
    print(f"Use case: {USE_CASE}")
    print(f"Connecting to Azure AI Search: {SEARCH_ENDPOINT}")

    credential = AzureKeyCredential(SEARCH_KEY)
    index_client = SearchIndexClient(endpoint=SEARCH_ENDPOINT, credential=credential)
    indexer_client = SearchIndexerClient(endpoint=SEARCH_ENDPOINT, credential=credential)

    print("\n--- Creating Search Index ---")
    create_index(index_client)

    print("\n--- Creating Cosmos DB Data Source Connection ---")
    create_data_source(indexer_client)

    print("\n--- Creating Indexer with Daily Schedule ---")
    create_indexer(indexer_client)

    print("\n--- Running Indexer (initial population) ---")
    indexer_client.run_indexer(INDEXER_NAME)
    print(f"Indexer '{INDEXER_NAME}' started. Initial indexing in progress...")
    print("The indexer will also run automatically every day at 8:00 AM PST.")
    print("\nDone! AI Search index setup complete for Cosmos DB data source.")


if __name__ == "__main__":
    main()