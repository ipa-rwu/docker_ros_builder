#!/bin/bash

set -e
set -o pipefail
function builder_setup {
    apt_get_install python3-colcon-common-extensions python3-catkin-pkg python3-pip
    python3 -m pip install catkin_pkg
}
function grep_opt {
    grep "$@" || [[ $? = 1 ]]
}
function update_list {
    local ws=$1
    shift
    setup_rosdep
    if [ -f "$ws"/src/extra.sh ]; then
        "$ws"/src/extra.sh
    fi
}
function run_sh_files() {
    local ws=$1
    shift
    local sh_files=("$@")
    setup_rosdep
    for file in "${sh_files[@]}"; do
        if [ -f "$ws"/src/"$file" ]; then
            chmod +x "$ws"/src/"$file"
            "$ws"/src/"$file"
        fi
    done
}
function read_depends {
    local src=$1
    shift
    for dt in "$@"; do
        grep_opt -rhoP "(?<=<$dt>)[\w-]+(?=</$dt>)" "$src"
    done
}
function list_packages {
    if [ "$ROS_VERSION" -eq 1 ]; then
        local src=$1
        shift
        "/opt/ros/$ROS_DISTRO"/env.sh catkin_topological_order --only-names "/opt/ros/$ROS_DISTRO/share"
        "/opt/ros/$ROS_DISTRO"/env.sh catkin_topological_order --only-names "$src"
    fi
    if [ "$ROS_VERSION" -eq 2 ]; then
        if ! command -v colcon >/dev/null; then
            apt_get_install python3-colcon-common-extensions
        fi
        local src=$1
        shift
        colcon list --base-paths "/opt/ros/$ROS_DISTRO/share" --names-only
        colcon list --base-paths "$src" --names-only
    fi
}
function setup_rosdep {
    source "/opt/ros/$ROS_DISTRO/setup.bash"
    if [ "$ROS_VERSION" -eq 1 ]; then
        if [ "$ROS_DISTRO" == "noetic" ]; then
            if ! command -v rosdep >/dev/null; then
                apt_get_install python3-rosdep >/dev/null
            fi
        else
            if ! command -v rosdep >/dev/null; then
                apt_get_install python-rosdep >/dev/null
            fi
        fi
    fi
    if [ "$ROS_VERSION" -eq 2 ]; then
        if ! command -v rosdep >/dev/null; then
            apt_get_install python3-rosdep >/dev/null
        fi
    fi

    if command -v sudo >/dev/null; then
        sudo rosdep init || true
    else
        rosdep init | true
    fi
    rosdep update
}
function resolve_depends {
    if [[ "$ROS_VERSION" -eq 1 ]]; then
        local src=$1
        shift
        comm -23 <(read_depends "$src" "$@" | sort -u) <(list_packages "$src" | sort -u) | xargs -r "/opt/ros/$ROS_DISTRO"/env.sh rosdep resolve | grep_opt -v '^#' | sort -u
    fi
    if [[ "$ROS_VERSION" -eq 2 ]]; then
        local src=$1
        shift
        comm -23 <(read_depends "$src" "$@" | sort -u) <(list_packages "$src" | sort -u) | xargs -r rosdep resolve | grep_opt -v '^#' | sort -u
    fi
    if [ "$ROS_VERSION" -ne 2 ] && [ "$ROS_VERSION" -ne 1 ]; then
        echo "Cannot get ROS_VERSION"
        exit 1
    fi
}

function apt_get_install {
    local cmd=()
    if command -v sudo >/dev/null; then
        cmd+=(sudo)
    fi
    cmd+=(apt-get install --no-install-recommends -qq -y)
    if [ -n "$*" ]; then
        "${cmd[@]}" "$@"
    else
        xargs -r "${cmd[@]}"
    fi
}

function pass_ci_token {
    local rosinstall_file=$1
    shift
    if ! command -v gettext >/dev/null; then
        apt_get_install gettext >/dev/null
    fi
    sed -i 's/https:\/\/git-ce\./https:\/\/gitlab-ci-token:\$\{CI_JOB_TOKEN\}\@git-ce\./g' "$rosinstall_file"
    # Replace CI_JOB_TOKEN by its content
    envsubst <"$rosinstall_file" >tmp.rosinstall
    rm "$rosinstall_file"
    mv tmp.rosinstall "$rosinstall_file"
}

function install_from_rosinstall {
    local rosinstall_file=$1
    local location=$2
    # install vcstool
    source "/opt/ros/$ROS_DISTRO/setup.bash"
    if ! command -v vcstool >/dev/null; then
        if [[ "$ROS_VERSION" -eq 1 ]]; then
            # echo "It is: $ROS_VERSION"
            if [ "$ROS_DISTRO" = "noetic" ]; then
                # echo "It is: $ROS_DISTRO"
                apt_get_install python3-vcstool >/dev/null
            else
                apt_get_install python-vcstool >/dev/null
            fi
        fi
        if [[ "$ROS_VERSION" -eq 2 ]]; then
            # echo "It is: $ROS_DISTRO, $ROS_VERSION"
            apt_get_install python3-vcstool >/dev/null
        fi
        if [[ "$ROS_VERSION" -ne 2 ]] && [[ "$ROS_VERSION" -ne 1 ]]; then
            echo "Cannot get ROS_VERSION"
            exit 1
        fi
    fi
    # install git
    if ! command -v git >/dev/null; then
        apt_get_install git >/dev/null
    fi
    # echo "ROSINSTALL_CI_JOB_TOKEN = $ROSINSTALL_CI_JOB_TOKEN"
    # Use GitLab CI tokens if required by the user
    # This allows to clone private repositories using wstool
    # Requires the private repositories are on the same GitLab server
    if [[ "${ROSINSTALL_CI_JOB_TOKEN}" == "true" ]]; then
        echo "Modify rosinstall file to use GitLab CI job token"
        pass_ci_token "${rosinstall_file}" >/dev/null
    fi
    # echo "vcs import"
    # cat "$rosinstall_file"
    vcs import "$location" <"$rosinstall_file"
    rm "$rosinstall_file"
}

function install_from_rosinstall_folder {
    local ws=$1
    shift
    for f in $(find "$ws/src" -type f -name '*.repos' -o -name "*.repo"); do
        echo "Find $f"
        install_from_rosinstall "$f" "$ws/src"
    done
}

function install_dep_python {
    local ws=$1
    shift
    for f in $(find "$ws" -type f -name 'requirements.txt'); do
        echo "Find $f"
        # install pip
        if ! command -v pip >/dev/null; then
            if ! command -v python >/dev/null; then
                apt_get_install python3-pip >/dev/null
            else
                apt_get_install python-pip >/dev/null
            fi
        fi
        pip install -r "$f"
    done
}

# download_repos "workspace name"
function download_repos {
    local ws=$1
    shift
    for file in $(find "$ws/src" -type f -name '*.rosinstall' -o -name 'rosinstall' -o -name '*.repo' -o -name '*.repos'); do
        echo "$file"
        install_from_rosinstall "$file" "$ws"/src/
    done
}

# get_dependencies "workspace name" "ROS_DISTRO name" "ubderlayered workspace(s)"
function get_dependencies {
    # require source workspace before
    local ws=$1
    shift
    local ROS_DISTRO=$1
    shift

    local overlayer_wss="$*"
    local wss
    if [[ -n "${overlayer_wss[@]}" ]]; then
        for ele in "${overlayer_wss[@]}"; do
            wss+=("$ele")
        done
    fi

    setup_rosdep

    local ROS_VERSION=0
    if [ "$ROS_DISTRO" = "noetic" ]; then
        export ROS_VERSION=1
    elif [ "$ROS_DISTRO" = "humble" ]; then
        export ROS_VERSION=2
    fi

    download_repos "$ws"

    resolve_depends "$ws/src" depend build_export_depend exec_depend run_depend >"$ws/DEPENDS"
    resolve_depends "$ws/src" depend build_depend build_export_depend | apt_get_install
}

# setup_ws --ros_distro "ROS_DISTRO name" --overlayers "ubderlayered workspace(s)"
function setup_ws {
    local rest="$*"
    while [[ $rest =~ (.*)"--"(.*) ]]; do
        IFS=' ' read -ra eles <<<"${BASH_REMATCH[2]}"
        v="${eles[0]}"
        if [[ -n "${eles[@]:1}" ]]; then
            declare -a "$v"="( $(printf '%q ' "${eles[@]:1}") )"
        fi

        unset IFS
        rest=${BASH_REMATCH[1]}
    done

    if [ -v "${ros_distro}" ]; then
        source "/opt/ros/$ros_distro/setup.bash"
    else
        source "/opt/ros/$ROS_DISTRO/setup.bash"
    fi

    if [[ -n "${overlayers[@]}" ]]; then
        for overlayer in "${overlayers[@]}"; do
            if [ -f "$overlayer/install/local_setup.bash" ]; then
                source "$overlayer/install/local_setup.bash"
            fi
        done
    fi
}

# only_build_workspace "workspace path" "ROS_DISTRO name" --overlayers "ubderlayered workspace(s)" --pkgs "select pkgs"
function only_build_workspace {
    # require source workspace before
    local ws=$1
    shift
    local ROS_DISTRO=$1
    shift

    apt_get_install build-essential

    local rest="$*"
    shift
    while [[ $rest =~ (.*)"--"(.*) ]]; do
        IFS=' ' read -ra eles <<<"${BASH_REMATCH[2]}"
        v="${eles[0]}"
        if [[ -n "${eles[@]:1}" ]]; then
            declare -a "$v"="( $(printf '%q ' "${eles[@]:1}") )"
        fi

        unset IFS
        rest=${BASH_REMATCH[1]}
    done

    if [[ -n "${overlayers[@]}" ]]; then
        setup_ws --ros_distro "$ROS_DISTRO" --overlayers "${overlayers[@]}"
    else
        setup_ws --ros_distro "$ROS_DISTRO"
    fi

    local ROS_VERSION=0
    if [ "$ROS_DISTRO" = "noetic" ]; then
        export ROS_VERSION=1
    elif [ "$ROS_DISTRO" = "humble" ]; then
        export ROS_VERSION=2
    fi

    if [[ "$ROS_VERSION" -eq 1 ]]; then
        local cmd=("/opt/ros/$ROS_DISTRO"/env.sh catkin_make_isolated -C "$ws")
        if [[ -n "${pkgs[@]}" ]]; then
            echo "pkgs=${pkgs[@]}"
            cmd+=(--pkg)
            for pkg in "${pkgs[@]}"; do
                cmd+=("$pkg")
            done
        fi

        cmd+=(-DCATKIN_ENABLE_TESTING=0)

        if [[ -n "${CMAKE_ARGS[@]}" ]]; then
            for str in "${CMAKE_ARGS[@]}"; do
                cmd+=("$str")
            done
        fi
        echo "cmd=${cmd[@]}"
        ${cmd[@]}
    fi

    if [[ "$ROS_VERSION" -eq 2 ]]; then
        if ! command -v colcon >/dev/null; then
            apt_get_install python3-colcon-common-extensions
        fi
        local cmd=(colcon build)
        if [[ -n "${pkgs[@]}" ]]; then
            if [[ -n "${COLCON_OPTION}" ]]; then
                cmd+=("${COLCON_OPTION}")
            else
                cmd+=(--packages-up-to)
            fi
            for pkg in "${pkgs[@]}"; do
                cmd+=("$pkg")
            done
        fi

        if [[ -n "${CMAKE_ARGS[@]}" ]]; then
            cmd+=("--cmake-args")
            for str in "${CMAKE_ARGS[@]}"; do
                cmd+=("$str")
            done
        fi

        cd "$ws" && ${cmd[@]}
    fi
}

function build_workspace {
    local ws=$1
    shift
    local pkgs="$*"
    apt_get_install build-essential
    setup_rosdep
    source "/opt/ros/$ROS_DISTRO/setup.bash"
    # ls "$ws"/src

    # download repos from .rosinstall or .repo, or .repos
    download_repos "$ws"

    resolve_depends "$ws/src" depend build_export_depend exec_depend run_depend >"$ws/DEPENDS"
    resolve_depends "$ws/src" depend build_depend build_export_depend | apt_get_install

    # install python deps
    install_dep_python "$ws/src"
    echo "CMAKE_ARGS = $CMAKE_ARGS"

    if [[ "$ROS_VERSION" -eq 1 ]]; then
        local cmd=("/opt/ros/$ROS_DISTRO"/env.sh catkin_make_isolated -C "$ws")
        if [[ -n "${pkgs[@]}" ]]; then
            cmd+=(--pkg)
            for pkg in "${pkgs[@]}"; do
                cmd+=("$pkg")
            done
        fi

        cmd+=(-DCATKIN_ENABLE_TESTING=0)

        if [[ -n "${CMAKE_ARGS[@]}" ]]; then
            for str in "${CMAKE_ARGS[@]}"; do
                cmd+=("$str")
            done
        fi
        ${cmd[@]}
    fi

    if [[ "$ROS_VERSION" -eq 2 ]]; then
        if ! command -v colcon >/dev/null; then
            apt_get_install python3-colcon-common-extensions
        fi
        local cmd=(colcon build)
        if [[ -n "${pkgs[@]}" ]]; then
            if [[ -n "${COLCON_OPTION}" ]]; then
                cmd+=("${COLCON_OPTION}")
            else
                cmd+=(--packages-up-to)
            fi
            for pkg in "${pkgs[@]}"; do
                cmd+=("$pkg")
            done
        fi

        if [[ -n "${CMAKE_ARGS[@]}" ]]; then
            cmd+=("--cmake-args")
            for str in "${CMAKE_ARGS[@]}"; do
                cmd+=("$str")
            done
        fi

        cd "$ws" && ${cmd[@]}
    fi
}

function test_workspace {
    local ws=$1
    shift
    local pkgs="$*"
    source "/opt/ros/$ROS_DISTRO/setup.bash"
    resolve_depends "$ws/src" depend exec_depend run_depend test_depend | apt_get_install
    if [[ "$ROS_VERSION" -eq 1 ]]; then
        "/opt/ros/$ROS_DISTRO"/env.sh catkin_make_isolated -C "$ws" -DCATKIN_ENABLE_TESTING=1
        "/opt/ros/$ROS_DISTRO"/env.sh catkin_make_isolated -C "$ws" --make-args run_tests -j1
        "/opt/ros/$ROS_DISTRO"/env.sh catkin_test_results --verbose "$ws"
    else
        if ! command -v colcon >/dev/null; then
            apt_get_install python3-colcon-common-extensions
        fi
        local cmd=(colcon test)
        if [[ -n "${pkgs[@]}" ]]; then
            if [[ -n "${COLCON_OPTION}" ]]; then
                cmd+=("${COLCON_OPTION}")
            else
                cmd+=(--packages-up-to)
            fi
            for pkg in "${pkgs[@]}"; do
                cmd+=("$pkg")
            done
        fi

        cd "$ws" && ${cmd[@]}
        colcon test-result --verbose
    fi
}

function install_depends {
    local ws=$1
    shift
    apt_get_install <"$ws/DEPENDS"
}

function install_workspace {
    source "/opt/ros/$ROS_DISTRO/setup.bash"
    echo "ROS_VERSION: $ROS_VERSION"
    echo "ROS_DISTRO: $ROS_DISTRO"
    if [[ "$ROS_VERSION" -eq 1 ]]; then
        echo "It is: $ROS_DISTRO"
        local ws=$1
        shift
        "/opt/ros/$ROS_DISTRO"/env.sh catkin_make_isolated -C "$ws" --install --install-space "/opt/ros/$ROS_DISTRO"
    fi
    if [[ "$ROS_VERSION" -eq 2 ]]; then
        echo "It is: $ROS_DISTRO"
        local ws=$1
        shift
        rm -r "$ws"/build
        make_ros_entrypoint "$ws" >/ros_entrypoint.sh
        source "/ros_entrypoint.sh"
    fi
    if [[ "$ROS_VERSION" -ne 2 ]] && [[ "$ROS_VERSION" -ne 1 ]]; then
        exit 1
    fi
}

function make_ros_entrypoint {
    local ws=$1
    shift
    cat <<-_EOF_
#!/bin/bash
set -e

# setup ros2 environment
source "/opt/ros/$ROS_DISTRO/setup.bash" --
if [ -f "$ws"/install/setup.bash ]; then
source "$ws/install/setup.bash" --
fi
exec "\$@"
_EOF_
}

if [ -n "$*" ]; then
    "$@"
fi
