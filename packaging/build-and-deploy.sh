#!/bin/sh
# Builds the Debian 13 package and deploys it to the servers of packaging/ansible/inventory.yml.
#
#   packaging/build-and-deploy.sh                       # build, then deploy to every server
#   packaging/build-and-deploy.sh --limit euWorker1     # arguments go to ansible-playbook
#   packaging/build-and-deploy.sh --check --diff        # what a deployment would change
#   packaging/build-and-deploy.sh --ask-become-pass     # when sudo on the servers asks for a password
#   RUN_TESTS=1 packaging/build-and-deploy.sh           # run the tests in the build first
#   SKIP_BUILD=1 packaging/build-and-deploy.sh          # deploy the package that is built already
#
# Needs Docker and Ansible. See packaging/ansible/README.md for the inventory and the cookie.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
ansible="$here/ansible"

# Before the build, which takes minutes: is there anything to deploy to?
inventory_given=0 vault_given=0
for arg in "$@"; do
  case "$arg" in
    -i | -i* | --inventory | --inventory=* | --inventory-file | --inventory-file=*) inventory_given=1 ;;
    -J | --ask-vault-pass | --ask-vault-password | --vault-id | --vault-id=* | --vault-password-file | --vault-password-file=* | --vault-pass-file | --vault-pass-file=*) vault_given=1 ;;
  esac
done

if [ "$inventory_given" = 0 ] && [ ! -f "$ansible/inventory.yml" ]; then
  echo "error: $ansible/inventory.yml is missing; copy inventory.example.yml and add your servers" >&2
  exit 2
fi

command -v ansible-playbook >/dev/null || { echo "error: ansible-playbook is not installed" >&2; exit 2; }

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  "$here/debian/build.sh"
fi

# A cookie in a vault needs its password; ask for it unless a vault option or file is given.
if [ "$vault_given" = 0 ] && [ -z "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ] &&
  grep -rqs '\$ANSIBLE_VAULT' "$ansible/group_vars" "$ansible/host_vars"; then
  set -- --ask-vault-pass "$@"
fi

# From the caller's directory, so relative paths in the arguments stay right; ansible.cfg
# resolves its own paths, inventory.yml and roles, from where it is.
ANSIBLE_CONFIG="$ansible/ansible.cfg" exec ansible-playbook "$ansible/deploy.yml" "$@"
