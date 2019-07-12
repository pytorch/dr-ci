Contributing
============

1. Open a pull request on GitHub


# Setup

## Prerequisites

Ubuntu packages:

    sudo apt-get install libgmp3-dev libpq-dev


Architecture notes
=============

Log storage
-----------

Console logs are stored in the Postgres database. Since large string fields (including `text` datatype)
are [automatically "TOAST"ed](https://stackoverflow.com/a/3801515/105137), this sidesteps the issue
of implementing compression.


Local testing
===========

### Without docker

To run the scanner with a fresh database:

    stack run run-scanner -- --wipe --count 10 --branch master


To run the scanner on some specific Pull Requests:

    stack run run-scanner -- --wipe --count 50 --branch pull/18339 --branch pull/18340 --branch pull/18341 --branch pull/18342 --branch pull/18343 --branch pull/18907


To launch the server, run the following from the `haskell/` directory:

    find -name "*.tix" -delete && stack run my-webapp -- --data-path static


### With docker

To test the server locally via Docker:

    docker run -p 3001:3001 -it circleci-failure-tracker-img-my-webapp


Deployment procedure
===========

Build the docker container with the following command:

    stack image container --docker


Note that we *do not* want the following in `stack.yaml`, because it breaks Intero in emacs.  The above `--docker` option takes its place.

    docker:
      enable: true

Tag the image:

    docker tag circleci-failure-tracker-img-small-my-webapp kostmo/circleci-failure-tracker-img-small-my-webapp

Push the image:

    docker push kostmo/circleci-failure-tracker-img-small-my-webapp

Redeploy webapp via `Dockerrun.aws.json`



#### Troubleshooting

If you need to start over, you can drop the database with:

    sudo -u postgres dropdb loganci


### Capturing the database schema

Ran this command:

    ./update-database-schema.sh