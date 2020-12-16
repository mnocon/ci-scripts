#!/bin/bash
set -e

PROJECT_VARIANT=$1
COMPOSE_FILE=$2

echo "> Setting up website skeleton"
EZPLATFORM_BUILD_DIR=${HOME}/build/ezplatform
# export SYMFONY_ENDPOINT=https://flex.ibexa.co #TMP
composer create-project ibexa/website-skeleton:^1.0@dev ${EZPLATFORM_BUILD_DIR} --no-scripts --repository=https://webhdx.repo.repman.io #TMP

DEPENDENCY_PACKAGE_DIR=$(pwd)

# Get details about dependency package
DEPENDENCY_PACKAGE_NAME=`php -r "echo json_decode(file_get_contents('${DEPENDENCY_PACKAGE_DIR}/composer.json'))->name;"`
if [[ -z "${DEPENDENCY_PACKAGE_NAME}" ]]; then
    echo 'Missing composer package name of tested dependency' >&2
    exit 2
fi

echo '> Preparing project containers using the following setup:'
echo "- EZPLATFORM_BUILD_DIR=${EZPLATFORM_BUILD_DIR}"
echo "- DEPENDENCY_PACKAGE_NAME=${DEPENDENCY_PACKAGE_NAME}"

# get dependency branch alias
BRANCH_ALIAS=`php -r "echo json_decode(file_get_contents('${DEPENDENCY_PACKAGE_DIR}/composer.json'))->extra->{'branch-alias'}->{'dev-tmp_ci_branch'};"`
if [[ $? -ne 0 || -z "${BRANCH_ALIAS}" ]]; then
    echo 'Failed to determine branch alias. Add extra.branch-alias.dev-tmp_ci_branch config key to your tested dependency composer.json' >&2
    exit 3
fi

# Link dependency to directory available for docker volume
echo "> Link ${DEPENDENCY_PACKAGE_DIR} to ${EZPLATFORM_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}"
mkdir -p ${EZPLATFORM_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}
ln -s ${DEPENDENCY_PACKAGE_DIR}/* ${EZPLATFORM_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}/

# # perform full checkout to allow using as local Composer depenency
# cd ${EZPLATFORM_BUILD_DIR}/${BASE_PACKAGE_NAME}
# git fetch --unshallow

# echo "> Create temporary branch in ${DEPENDENCY_PACKAGE_NAME}"
# # reuse HEAD commit id for better knowledge about what got checked out
# TMP_TRAVIS_BRANCH=tmp_`git rev-parse --short HEAD`
# git checkout -b ${TMP_TRAVIS_BRANCH}

# go back to previous directory

# use local checkout path relative to docker volume
cd ${EZPLATFORM_BUILD_DIR}

# Make sure .env exists
touch .env

# Install package with Docker Compose files
composer config repositories.docker vcs https://github.com/mnocon/docker.git #TMP
composer require --no-update --prefer-dist mnocon/docker:^1.0@dev
composer require --no-update --prefer-dist ezsystems/behatbundle:^8.0@dev
composer update mnocon/docker --no-scripts
composer recipes:install mnocon/docker
rm composer.lock # remove lock created for Docker dependency

echo "> Make composer use tested dependency"
composer config repositories.localDependency path ./${DEPENDENCY_PACKAGE_NAME}

echo "> Require ${DEPENDENCY_PACKAGE_NAME}:dev-${TMP_TRAVIS_BRANCH} as ${BRANCH_ALIAS}"
composer require --no-update "${DEPENDENCY_PACKAGE_NAME}:${BRANCH_ALIAS}"

# Install correct product variant
composer require ibexa/${PROJECT_VARIANT} --no-scripts --no-update

echo "> Install DB and dependencies - use Docker for consistent PHP version"
docker-compose -f doc/docker/install-dependencies.yml up --abort-on-container-exit

echo '> Install data'
docker-compose exec --user www-data app sh -c "export DATABASE_URL=${DATABASE_PLATFORM}://${DATABASE_USER}:${DATABASE_PASSWORD}@${DATABASE_HOST}:${DATABASE_PORT}/${DATABASE_NAME}?serverVersion=${DATABASE_VERSION} ; php /scripts/wait_for_db.php; php bin/console ezplatform:install clean" #TMP 1) hardcoded DB


echo "> Start docker containers specified by ${COMPOSE_FILE}"
docker-compose up -d

# for Behat builds to work
echo '> Change ownership of files inside docker container'
docker-compose exec app sh -c 'chown -R www-data:www-data /var/www'

echo '> Install data'
docker-compose exec --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ezplatform:install clean" #TMP 1) hardcoded DB

echo '> Generate GraphQL schema'
docker-compose exec --user www-data app sh -c "php bin/console ezplatform:graphql:generate-schema"
docker-compose exec --user www-data app sh -c "composer run post-install-cmd"

echo '> Done, ready to run tests'

cd "$HOME/build/ezplatform"; 
