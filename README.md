# OpenG2P Developer Setup

Orchestration repo to bootstrap local OpenG2P development (infra in Docker; apps native or Docker images).

**Full documentation:** [https://docs.openg2p.org/tools/openg2p-developer-setup](https://docs.openg2p.org/tools/openg2p-developer-setup)

**Source:** [https://github.com/OpenG2P/openg2p-developer](https://github.com/OpenG2P/openg2p-developer)

## Quick start (Docker Farmer Registry)

```bash
git clone https://github.com/OpenG2P/openg2p-developer.git
cd openg2p-developer
cp .env.example .env
sed -i 's/^USE_EXTERNAL_REDIS=.*/USE_EXTERNAL_REDIS=false/' .env
make sync-images
make docker-farmer-up
```

Default ports and credentials are defined in `.env.example`.

| URL | Port (default) |
| --- | -------------- |
| Staff Portal hub | http://localhost:3000 |
| Farmer Registry UI | http://localhost:3001 |
| NSR UI | http://localhost:3002 |
| Keycloak | http://localhost:8080 |

| User | Password |
| ---- | -------- |
| `staff` | `staff` |
| `alex.carter` | `pass` |
| `nina.patel` | `pass` |
| `admin` (Keycloak) | `admin` |

```bash
make help
```

## License

[Mozilla Public License 2.0](LICENSE)
