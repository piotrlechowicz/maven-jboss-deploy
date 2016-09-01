#!/bin/bash

### java artifact deployer ###

#set -x
script_debug=true
####-------- PRECONDITIONS -------####

# checks if jq package for parsing json is installed
if [[ ! `dpkg -s 'jq' | grep 'ok install'` ]]; then
    echo "Please install jq package for parsing json"
    echo `dpkg-query -l 'jq'`
    exit 42
fi

json_file="jad-conf.json"   # json file with deployment profile configuration

if [ ! -e "$json_file" ]; then                              # check if json file exists
    echo "Missing json configuration file: $json_file"
    exit 42
fi

# if file is invoked without parameters
if [ $# -eq 0 ]; then
	echo "executing version without arguments"  #TODO: change to show help
    exit 42
fi

#### DECLARE VARIABLES ####

# possible options
build_modules=false # if jar modules should be build
build_ear=false     # if ear module should be build
deploy=false        # if ear should be deployed on server
show_errors=false   # if maven should show errors
skip_tests=false    # if maven should skip tests
profile="default"   # deployment profile from json file
debug=false         # if maven should show debug
quiet=false         # if maven should be run in quiet mode

server_path=""      # path where artifact should be copied
modules_paths=()    # path to folders where maven creates jar modules
ear_maven_path=""   # path to folder where maven creates ear
ear_path=""         # path where output ear is stored
ear_name=""         # name of an ear


# this function parses parameters in short format ( -zxcv )
# it only parses if the parameters start with single hyphenation
# if there are many parameters combined as (-zxc) it splits them into (-z -x -c)
#
# param $1: parameter to parse
# return: number of parsed parameters (if it is greater than 0 the main argument parameters should be parsed)
function parse_short_parameters {
    local parameters=()
    # checking if there is parameter with single hyphenation------------------
    if [[ $(expr match $1 "-[a-zA-Z]") -gt 0 ]]; then
        result="true"
        # if there are at least two parameters (the first one is hyphenation)
        if [[ ${#1} -gt 2 ]]; then
            # substring from first character
            parameters_to_split=${1:1}

            # append each character with hyphenation to list of parameters
            for char in $(echo $parameters_to_split | fold -w1); do
                parameters+=("$char")
            done
        fi
    fi
    # if the number of parameters is greater than zero, parse them
    if [[ ${#parameters[@]} -gt 0 ]]; then
        for i in "${!parameters[@]}"; do
            case ${parameters[$i]} in
                b)
                    #Set build modules to true"
                    build_modules=true
                    ;;
                d)
                    #Set deploy ear to true"
                    deploy=true
                    ;;
                e)
                    #Set deploy ear to true"
                    build_ear=true
                    ;;
                r)
                    #Set show errors to true
                    show_errors=true
                    ;;
                s)
                    #Set skip tests to true
                    skip_tests=true
                    ;;
                X)
                    #Set debug
                    debug=true
                    ;;
                q)
                    #Set quiet
                    quiet=true
                    ;;
                *)
                    echo "Cannot recognize command"
                    echo "I'm showing help..."
                    exit
                    ;;
            esac
        done
    fi
    return ${#parameters[@]}
}

# this function parses parameters in long format ( -zzz -xxx -yyy)
#
# param $#: list of arguments to parse
# return: nothing
function parse_long_parameters {
    # iterate through the command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -b | --build)       shift
                                #Set build modules to true"
                                build_modules=true
                                ;;
            -d | --deploy)      shift
                                #Set deploy ear to true"
                                deploy=true
                                ;;
            -e | --ear)         shift
                                #Set deploy ear to true"
                                build_ear=true
                                ;;
            -p | --profile)     shift
                                #Set profile to $1"
                                profile=$1
                                shift
                                ;;
            -r | --show-errors) shift
                                #Set show errors to true
                                show_errors=true
                                ;;
            -s | --skip-tests)  shift
                                #Set skip tests to true
                                skip_tests=true
                                ;;
            -q | --quiet)       shift
                                #Set quiet to true
                                quiet=true
                                ;;
            -X | --debug)       shift
                                #Set debug to true
                                debug=true
                                ;;
            -h | --help)		shift
                                echo "I'm showing help..."
                                exit
                                ;;
            *)					shift
                                echo "Cannot recognize command"
                                echo "I'm showing help..."
                                exit
                                ;;
        esac
    done;
}

# removes prefix and suffix " if they exist in the variable
#
# param $1: variable to sanitize
# returns sanitized variable
function sanitize_variable {
    local variable=$1
    variable=${variable%\"} # removing suffix
    variable=${variable#\"} # removing prefix
    echo $variable
}

# parses deployment profile details from json file
# there are fetched following variables:
#   $server_path, $ear_mvn_path, $ear_path, $ear_name, ${modules_path[*]}
# if fetching fails, the variable will store 'null' string
#
# param $1: deployment profile
# return: nothing
function parse_profile {
    local profile=$1
    profile_json=$(cat $json_file | jq ".profiles.\"$profile\"")

    if [[ $profile_json == "null" ]]; then
        echo "provided provile does not exist"
        exit 5
    fi;

    # maybe to remove???
#    servers_json=$(cat $json_file | jq ".servers")
#    ears_json=$(cat $json_file | jq ".ears")

    #fetching server (required - json file, and active profile
    temp=$(echo $profile_json | jq '.server')
    server_path=$(cat $json_file | jq ".servers.$temp")
    [ "$server_path" = null ] && server_path=$temp
    server_path=$(sanitize_variable $server_path)

    # fetching ears
    ear_json=$(echo $profile_json | jq '.ear')
    [ $(echo $ear_json | jq '. | type') = "\"string\"" ] && ear_json=$(cat $json_file | jq ".ears.$ear_json")

    if [[ $ear_json != "null" ]]; then
        ear_maven_path=$(sanitize_variable $(echo $ear_json | jq '.mvn_path'))
        ear_path=$(sanitize_variable $(echo $ear_json | jq '.ear_path'))
        ear_name=$(sanitize_variable $(echo $ear_json | jq '.name'))
    fi

    # fetching modules
    modules_json=$(echo $profile_json | jq '.modules')
    [ $(echo $modules_json | jq '. | type') = "\"string\"" ] && modules_json=$(cat $json_file | jq ".modules.$modules_json")

    for path in $(echo $modules_json | jq '.[]'); do
        modules_paths+=("$(sanitize_variable $path)")
    done


    if [[ "$script_debug" = true ]]; then
        echo -e "server path : $server_path
ear maven path : $ear_maven_path
ear path : $ear_path
ear name : $ear_name
modules paths : ${modules_paths[@]}\n"
    fi
}

# prepares maven command based on parsed input arguments
#
# return: prepared maven command
function prepare_maven_command {
    local maven_command="mvn"
    [ "$show_errors" = true ] && maven_command+=" -e";
    [ "$debug" = true ] && maven_command+=" -X"
    [ "$quiet" = true ] && maven_command+=" -q"
    [ "$skip_tests" = true ] && maven_command+=" -DskipTests=true"
    maven_command+=" clean install"
    echo $maven_command
}

# builds jar modules
function perform_building_modules {
    local maven_command=$1
    echo "Building modules: ${modules_paths[*]}"
    for module in ${modules_paths[*]}; do
        echo "Building module : $module"
        cd ${module} && $maven_command || echo "faild to build module: $module"
    done
}

# builds ear
function perform_building_ear {
    local maven_comand=$1
    echo "Building ear: $ear_maven_path"
    [ "$ear_maven_path" != "null" ] && [ -d "$ear_maven_path" ]  && cd $ear_maven_path &&
        $maven_command || echo "building ear failed"
}

# deploys ear on server
function perform_deploying_ear {
    local maven_command=$1
    echo "Deploying ear on server: $server_path"
    if [[ $server_path != "null" ]] && [[ $ear_path != "null" ]] && [[ $ear_name != "null" ]]; then
        #clear the server directory
        cd $server_path || return 1
        echo "removing deployed ear from server"
        [ -f "$ear_name" ] && rm -f $ear_name
        [ -f "${ear_name}.deployed" ] && rm -f "${ear_name}.deployed"

        echo "copying new ear to server"
        [ ! "$ear_path" == */ ] && ear_path="${ear_path}/"      # if path not ends with "/" append it
        cp "${ear_path}${ear_name}" "${server_path}" || echo "unsuccessful copy operation"
    fi
}

##### MAIN FLOW OF THE SCRIPT #####

parse_short_parameters $1
# parse short parameters returns information if any argument war parsed
# function returns how may arguments was parsed from single input
# if at least one was parsed input arguments should be moved
if [[ $? -gt 0 ]]; then
    shift
fi
parse_long_parameters $@

parse_profile $profile
maven_command=$(prepare_maven_command)

echo "executing with profile: $profile"
echo "maven command: $maven_command"

#[ $build_modules != false ] && perform_building_modules "$maven_command"
#[ $build_ear != false ] && perform_building_ear "$maven_command"
#[ $deploy != false ] && perform_deploying_ear "$maven_command"