# Deploying with Ansible

`deploy.yml` installs the Debian 13 package of `packaging/debian/build.sh` on the main servers, the workers and the
monitoring agents of an inventory, writes each worker's `/etc/aetherion/worker.env` and each agent's
`/etc/aetherion/agent.env`, starts their `aetherion-worker` and `aetherion-agent` services, also at boot, and checks
that every main server reaches every worker and agent. The servers need Debian 13 on amd64, SSH and sudo.

```sh
packaging/debian/build.sh                     # the package of the version in mix.exs
cd packaging/ansible
cp inventory.example.yml inventory.yml        # the servers, see below

# The cookie, the same on every server, in a vault
mkdir -p group_vars/all
ansible-vault encrypt_string "$(openssl rand -hex 32)" --name aetherion_cookie > group_vars/all/cookie.yml

ansible-playbook deploy.yml --ask-vault-pass
```

`inventory.yml`, `group_vars/` and `host_vars/` are not in git.

## Inventory

Three groups: `aetherion_main`, the servers that run suites, `aetherion_workers`, the servers that run their virtual
users, and `aetherion_agents`, the machines under test that a monitoring agent measures (C185). A server can be in
several. A worker's node name is `aetherion_worker_name@aetherion_worker_host` (C181), by
default its inventory name and its `ansible_host`, so `euWorker1` with `ansible_host: 10.0.0.11` is
`euWorker1@10.0.0.11`. The name needs letters, digits and `_`, and is the one suites read, as in
`loadGenerator.euWorker1.cpu.max()`. Set `aetherion_worker_host` when the main servers reach a worker at another
address than Ansible does.

An agent's node name is `aetherion_agent_name@aetherion_agent_host` the same way, and the name is the target of the
suites: `sutServer1` with `ansible_host: 10.0.0.21` is measured by

```
sut { sutServer1 { host = "10.0.0.21"; metrics = [cpu, mem, disk, net]; } }
monitoring { format = aetherion; }
```

| Variable                 | Default                                   |                                                     |
|--------------------------|-------------------------------------------|-----------------------------------------------------|
| `aetherion_cookie`       | none, required                            | at least 32 characters                              |
| `aetherion_deb`          | `../debian/dist/aetherion_<mix.exs version>-1_amd64.deb` | the package to install               |
| `aetherion_worker_name`  | the inventory name                        | a worker's name                                     |
| `aetherion_worker_host`  | `ansible_host`, or the inventory name     | the address the main servers reach a worker at      |
| `aetherion_dist_port`    | 4370                                      | a worker's distribution port; epmd stays on 4369    |
| `aetherion_agent_name`   | the inventory name                        | an agent's name, the target in the suites           |
| `aetherion_agent_host`   | `ansible_host`, or the inventory name     | the address the main servers reach an agent at      |
| `aetherion_agent_dist_port` | 4371                                   | an agent's distribution port, not the worker's      |
| `aetherion_ufw`          | false                                     | true: ufw rules on the workers and agents for the main servers |
| `aetherion_main_users`   | `[]`                                      | users of a main server who run suites               |

## Running a suite

On a main server, `/etc/aetherion/main.env` holds the cookie and the workers of the inventory, readable by root and
the group `aetherion`, which the users of `aetherion_main_users` join (log in again after the first deployment):

```sh
set -a; . /etc/aetherion/main.env; set +a
aetherion run shop.perf --config staging.perfcfg --workers "$AETHERION_WORKERS"
```

`--workers` replaces the workers section of the suite's Config (C184); without it, the run uses that section. The
agents need no option: the run connects to the agent of every target of the suite (C185).

## Upgrades

Build the package and run the playbook again. A package whose file changed goes in again even at the same version, as a
rebuild holds other code and the main server refuses a worker or an agent that runs other code; the package restarts
a running worker and agent. Deploy every server in the same run: with `--limit`, the others keep their version.

A changed `worker.env` restarts the worker, and a changed `agent.env` the agent. The playbook writes `worker.env` and `main.env` again on every run, so edit
the inventory, not the files. `apt purge aetherion` leaves `main.env`.

## Tags

`--skip-tags service` installs and configures without starting the workers and agents or checking that they are
reachable.
