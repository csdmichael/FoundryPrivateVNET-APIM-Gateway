# Support

This repository packages two Microsoft Teams agents that route requests through Azure API Management to a private Azure AI Foundry environment.

## What This App Does

- Tax PDF Forms Agent answers questions grounded in the indexed tax form PDFs configured in this repo.
- Eng Design PPT Agent answers questions grounded in the indexed engineering presentation files configured in this repo.

## Support Scope

Support for these packages covers:

- Teams app package installation issues
- Broken manifest links or packaging assets
- Message extension prompt submission issues
- API routing issues between Teams, APIM, and the private Foundry project

## Troubleshooting References

- Main project overview: https://github.com/csdmichael/FoundryPrivateVNET-APIM-Gateway
- Sample prompts: https://github.com/csdmichael/FoundryPrivateVNET-APIM-Gateway/blob/main/docs/Prompts.txt
- Deployment and configuration details: https://github.com/csdmichael/FoundryPrivateVNET-APIM-Gateway/blob/main/README.md

## Notes

These Teams packages are sample assets for the Foundry Private VNET APIM Gateway project. Responses depend on the currently deployed Azure resources, search indexes, and Foundry agent configuration.