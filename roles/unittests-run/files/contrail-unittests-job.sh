#!/usr/bin/env bash

set -o pipefail

function ci_exit() {
    exit_code=$1
    if [ -z $exit_code ]; then
        exit_code=0
    fi

    JENKINS_JOB_N=$(basename "$JOB_URL")
    if [ "$exit_code" == "0" ]; then
        #rm -rf $WORKSPACE/* $WORKSPACE/.* 2>/dev/null
        echo Success
        log_job_info_in_gerrit "Completed Jenkins job $JENKINS_JOB_N with SUCCESS"
    else
        # Leave the workspace intact.
        echo Exit with failed code $exit_code
        log_job_info_in_gerrit "Completed Jenkins job $JENKINS_JOB_N with FAILURE exit_code $exit_code"
    fi
    exit $exit_code
}

if [ -f "$SKIP_JOBS" ]; then
    echo Jobs skipped due to presence of file $SKIP_JOBS
    ci_exit
fi

function archive_failed_test_logs() {
    LOGFILE="unit_test_logs.tgz"
    find $WORKSPACE/repo/build -name "*.log" -o -name "*.err" |\grep test |  xargs tar --ignore-failed-read -zcf $WORKSPACE/$LOGFILE
    if [ ! -f "$WORKSPACE/$LOGFILE" ]; then
        return
    fi
    if [ -z "$BUILD_NUMBER" ]; then
        BUILD_NUMBER=0
    fi
    DST_DIR=/ci-admin/unit_test_logs/$JOB_NAME/$BUILD_NUMBER
}

function display_test_results() {
    log="$1"
    fail_log=$WORKSPACE/$(basename "$log" .log)-FAIL.log

    echo "*****************************************************************"
    echo "Displaying test results from: $log"

    grep -Ew 'FAIL|TIMEOUT' $log|grep -v 'FAIL:' > $fail_log
    FAIL_COUNT=$(cat $fail_log | wc -l)
    PASS_COUNT=$(grep -w PASS $log | wc -l)

    echo
    echo "Number of PASS tests: $PASS_COUNT"
    echo "Number of FAIL tests: $FAIL_COUNT"

    if [[ $FAIL_COUNT -ne 0 ]]; then
        echo
        echo unit-test failures:
        echo
        cat $fail_log
    fi
    echo "*****************************************************************"
}

function analyze_test_results() {
    log=$1

    echo "Analyzing test results in: $log"
    FAIL_COUNT=$(grep -Ew 'FAIL|TIMEOUT' $log | grep -v 'FAIL:' | wc -l)

    if [[ $FAIL_COUNT -ne 0 ]]; then
        echo unit-test failures: $FAIL_COUNT
        exit_status=1
    fi
}

function determine_retry_list() {
    f="$1"
    retry_list=$WORKSPACE/retry_tests.txt

    grep --color=no -Ew 'FAIL|TIMEOUT' $f \
    | grep -v 'FAIL:' \
    | sed -e 's=^ *\([^ ]*\) *\(FAIL\|TIMEOUT\).*$=\1=' \
    | sed -r  's/\x1b\[[0-9;]*m?//g' > $retry_list

    echo "Analyzing list of failed unit-tests:"
    echo "================================================================"
    cat $retry_list
    echo "================================================================"

    retry_targets=$WORKSPACE/retry_targets.txt
    touch $retry_targets
    while read tc; do
        # Easy case is a failed C++ unit-test, so add it as target and carry on
        if [[ -r $tc ]]; then
            echo $tc | sed -e "s=\($WORKSPACE/repo/.*\)=\1.log=" >> $retry_targets
            continue
        fi

        # Slightly harder, likely a python test and we have to find
        # the target that will rerun it
        bare_name=$(echo $tc | sed -e 's=[^_a-zA-Z0-9/]==g')

        py_file=$(find controller -name ${bare_name}.py -print)
        if [[ -n $py_file ]]; then
            py_file_count=$(echo $py_file | wc --words)
            if [[ $py_file_count -eq 1 ]]; then
            py_file_dir=$(dirname $py_file)
            bn=$(basename $py_file_dir)
            if [[ $bn =~ test ]]; then
                echo $(dirname $py_file_dir):test >> $retry_targets
                continue
            fi
            echo "Warn: $py_file does not appear to be in a test/tests dir"
            else
            echo "Warn: $py_file is not unique, cannot map to test target"
            fi
            echo "Warn: Cannot determine scons target to re-run failed test $tc"
            # rm -f $retry_list $retry_targets
            return 1
        fi

        # Let's see what repo grep shows us
        py_file=$(repo grep -l $bare_name)
        if [[ -n $py_file ]]; then
            py_file_count=$(echo $py_file | wc --words)
            if [[ $py_file_count -ge 1 ]]; then
            py_file_dir=$(dirname $py_file | sort -u)
            bn=$(basename $py_file_dir)
            if [[ $bn =~ test ]]; then
                echo py_file_dir=$py_file_dir
                echo $(dirname $py_file_dir):test >> $retry_targets
                continue
            fi
            echo "Warn: $py_file does not appear to be in a test/tests dir"
            else
            echo "Warn: $py_file is not unique, cannot map to test target"
            fi
            echo "Warn: Cannot determine scons target to re-run failed test $tc"
            # rm -f $retry_list $retry_targets
            return 1
        fi

        echo "Warn: Cannot determine scons target to re-run failed test $tc"
        # rm -f $retry_list $retry_targets
        return 1
        done < $retry_list

        UNIT_TESTS=$(sort -u < $retry_targets)
        # rm -f $retry_list $retry_targets

        # Final sanity check... if UNIT_TESTS is empty, we have definitely
        # failed to determine retry tests
        if [[ -z $UNIT_TESTS ]]; then
            echo "Warn: cannot determine list of unit-tests to retry"
            return 1
        fi
    return 0
}

# Run unittests
function run_unittest() {
    _EXTRA_UNITTESTS=$(set +o | grep xtrace)
    set +o xtrace

    # Goto the repo top directory.
    cd $WORKSPACE/repo

    export TASK_UTIL_WAIT_TIME=10000 # usecs
    export TASK_UTIL_RETRY_COUNT=6000
    export CONTRAIL_UT_TEST_TIMEOUT=1500
    export NO_HEAPCHECK=TRUE
    # This results in no -g flag during UT build, avoiding
    # disk-full failures for UT jobs.
    export CONTRAIL_COMPILE_WITHOUT_SYMBOLS=yes

    # Create CONTRAIL_REPO shortcut.
    export CONTRAIL_REPO=/home/$USER/contrail_repo
    rm -rf $CONTRAIL_REPO
    ln -sf $WORKSPACE/repo $CONTRAIL_REPO

    # Remove pip cache
    export PIP_CACHE=/home/$USER/.cache/pip
    [ -d $PIP_CACHE ] && rm -rf $PIP_CACHE

    # Find and run relevant tests.
    UNIT_TESTS=$($WORKSPACE/contrail-unittests-gather.rb)
    exit_code=$?
    if [ "$exit_code" != "0" ]; then
        echo "ERROR: Cannot determine unit-tests to run, exiting"
        ci_exit $exit_code
    fi

    if [[ -z $UNIT_TESTS ]]; then
        UNIT_TESTS=test
    fi

    logfile=$WORKSPACE/scons_test.log
    echo scons -k -j $SCONS_JOBS $UNIT_TESTS
    scons -k -j $SCONS_JOBS $UNIT_TESTS 2>&1 | tee $logfile
    exit_status=$?
    analyze_test_results $logfile

    # If unit test pass, show the results and exit
    if [[ $exit_status -eq 0 ]]; then
        display_test_results $logfile
        ci_exit 0
    fi

    echo "Warn: unit-test failed, will retry failed tests..."

    # if we didn't pass, then we might retry tests that had FAIL|TIMEOUT
    determine_retry_list $logfile
    rc=$?
    if [[ $rc -ne 0 ]]; then # Could not determine a list to retry
        display_test_results $logfile
        ci_exit $exit_status
    fi

    [ -d $PIP_CACHE ] && rm -rf $PIP_CACHE
    # do retry without -k flag
    retrylogfile=$WORKSPACE/scons_test_retry.log
    echo scons -j $SCONS_JOBS $UNIT_TESTS
    scons -j $SCONS_JOBS $UNIT_TESTS 2>&1 | tee $retrylogfile
    exit_status=$?
    analyze_test_results $retrylogfile

    [[ $exit_status -eq 0 ]] && echo "SUCCESS on retry of failed unit tests"

    echo "info: displaying original FAIL unit-test results"
    display_test_results $logfile

    echo "info: displaying retry unit-test results"
    display_test_results $retrylogfile
    ci_exit $exit_status

    _XTRACE_UNITTESTS
}

function main() {
    run_unittest
    ci_exit
}

# Note down environment
env > $WORKSPACE/env.sh
main
