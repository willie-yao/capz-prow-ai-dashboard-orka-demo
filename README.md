# CAPZ Prow AI Dashboard Orka Demo

This repository is a concrete consumer reference for deploying
[`prow-ai-dashboard`](https://github.com/willie-yao/prow-ai-dashboard) for
Cluster API Provider Azure test results with Helm and experimental Orka
container analysis.

The repository is intentionally safe by default:

- scheduled fetching is suspended
- GitHub write actions are disabled
- Orka is assumed to be installed and managed by the cluster operator
- no credentials, cache state, traces, or generated dashboard data are stored
  here
- deployment to the `h100` context is prohibited

The functional consumer configuration and deployment scripts will be added
through reviewed pull requests. The final reference will pin an exact dashboard
prerelease and the verified Orka source prerequisite.

## License

Apache License 2.0. See [LICENSE](LICENSE).
