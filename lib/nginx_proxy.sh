#!/usr/bin/env bash
##########################################################################
# Copyright 2016 Vuid Pty Ltd 
# https://www.vuid.com
#
# This file is part of tredly-build.
#
# tredly-build is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# tredly-build is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with tredly-build.  If not, see <http://www.gnu.org/licenses/>.
##########################################################################

# Reloads Nginx
function nginx_reload() {
    local _jid="${1}"
    local _exitCode
    service nginx reload > /dev/null 2>&1
    
    _exitCode=$?
    
    if [[ ${_exitCode} -ne 0 ]]; then
        e_error "Failed to reload HTTP proxy"
    else
         e_verbose "Reloaded HTTP proxy" 
    fi
    return ${_exitCode}
}

# Creates a server file for nginx
function nginx_create_servername_file() {
    local _subdomain="${1}"
    local _filePath="${2}"
    local _certificate="${3}"
    local _certificateLine=""
    
    # make sure the certificate exists or nginx will error
    if [[ -n "${_certificate}" ]]; then
        _certificateLine=""
    fi
    
    # output the config to the file
    {
        # if a certificate was received then include https
        if [[ -n "${_certificate}" ]]; then
            # HTTPS
            echo "server {"
            echo "    listen ${_CONF_COMMON[httpproxy]}:443 ssl;"
            echo "    server_name ${_subdomain};"
            echo "    include sslconfig/${_certificate};"
            echo "}"
        else
            # HTTP
            echo "server {"
            echo "    listen ${_CONF_COMMON[httpproxy]}:80;"
            echo "    server_name ${_subdomain};"
            echo "}"
        fi
    } > "${_filePath}"
    
    return $?
}

# Creates an upstream file for nginx
function nginx_create_upstream_file() {
    local _upstreamName="${1}"
    local _filePath="${2}"
    {
        echo "upstream ${_upstreamName} {"
        echo "}"
    } > "${_filePath}"
    return $?
}

# Adds an ip4 and port to an upstream block within an upstream file
function nginx_add_to_upstream_block() {
    local _file="${1}"
    local _ip4="${2}"
    local _port="${3}"
    local _upstreamName="${4}"

    # include the server line in the upstream file
    local _lineToAdd="server ${_ip4}:${_port};"

    # check if the server line exists
    local _lineExists=$(cat "${_file}" | grep "${_lineToAdd}" | wc -l )

    if [[ ${_lineExists} -eq 0 ]]; then
        # add in the ip address and port
        add_line_to_file_after_string "    ${_lineToAdd}" "upstream ${_upstreamName} {" "${_file}"
    fi
}

# adds the location data to the upstream file if it doesnt already exist
function nginx_add_location_block() {
    local _urlPath="${1}"
    local _filePath="${2}"
    local _ssl="${3}"

    local _listenLine="listen ${_CONF_COMMON[httpproxy]}"
    
    local locationExists

    # check if this definition already exists in the nginx config
    if [[ $(cat "${_filePath}" | grep "location ${_urlPath} {" | wc -l ) -eq 0 ]]; then
        # check if its an ssl location or not
        if [[ "${_ssl}" == "true" ]]; then
            _listenLine="${_listenLine}:443 ssl;"
        else
            _listenLine="${_listenLine}:80;"
        fi

        e_verbose "Adding location data to ${_filePath}"
        
        # add a fresh definition
        $(add_line_to_file_after_string "    location ${_urlPath} {" "${_listenLine}" "${_filePath}")
        # add the closing brace
        $(add_line_to_file_after_string "    }" "    location ${_urlPath} {" "${_filePath}")

        return ${E_SUCCESS}
    else
        e_verbose "Location data already in ${_filePath}"
        return ${E_ERROR}
    fi
    
}

# Inserts location data to a servername file
function nginx_insert_location_data() {
    local _upstreamFilename="${1}"
    local _urlDirectory="${2}"
    local _filePath="${3}"
    local _urlWebSocket="${4}"
    local _urlMaxFileSize="${5}"
    local _ssl="${6}"
    local _protocol="http"
    
    if [[ "${_ssl}" == "true" ]]; then
        _protocol="https"
    fi
    
    # get a copy of the location block
    local _locationBlock=$( get_data_between_strings "location ${_urlDirectory} {" "}" "$( cat "${_filePath}" )" )
    
    # now add in the proxy pass/bind
    # bind is necessary for the proxy request to come from the correct IP address
    add_line_to_file_between_strings_if_not_exists "location ${_urlDirectory} {" "        proxy_pass ${_protocol}://${_upstreamFilename};" "}" "${_filePath}"
    add_line_to_file_between_strings_if_not_exists "location ${_urlDirectory} {" "        proxy_bind ${_CONF_COMMON[httpproxy]};" "}" "${_filePath}"

    # check if this url is a websocket url and add in the relevant config
    if [[ "${_urlWebSocket}" == "yes" ]]; then
        add_line_to_file_between_strings_if_not_exists "location ${_urlDirectory} {" "        proxy_http_version 1.1;" "}" "${_filePath}"
        add_line_to_file_between_strings_if_not_exists "location ${_urlDirectory} {" '        proxy_set_header Upgrade $http_upgrade;' "}" "${_filePath}"
        add_line_to_file_between_strings_if_not_exists "location ${_urlDirectory} {" '        proxy_set_header Connection "upgrade";' "}" "${_filePath}"
        add_line_to_file_between_strings_if_not_exists "location ${_urlDirectory} {" "        proxy_read_timeout 600;" "}" "${_filePath}"
    fi

    # check if this url has a max file size setting
    if [[ -n "${_urlMaxFileSize}" ]]; then
        add_line_to_file_between_strings_if_not_exists "location ${_urlDirectory} {" "        client_max_body_size ${_urlMaxFileSize};" "}" "${_filePath}"
    fi
}

# creates an access file for a given location - includes allow and deny rules
function nginx_create_access_file() {
    local _accessFile="${1}"
    local -a _ip4wl=("${!2}")
    local _addDenyRule="${3}"
    
    local ip4wl
    local _accessDir=$( dirname "${_accessFile}" )
    
    # make sure the directory exists
    if [[ ! -d "${_accessDir}" ]]; then
        mkdir -p "${_accessDir}"
    fi

    # create the file
    touch "${_accessFile}"
    chmod 600 "${_accessFile}"
    
    # populate it
    {
        # make sure we have more than 0 ips to whitelist before adding the rules
        if [[ ${#_ip4wl[@]} -gt 0 ]]; then
            # loop over the whitelisted ips and allow them after validating
            for ip4wl in ${_ip4wl[@]}; do
                # validate it
                if is_valid_ip4 "${ip4wl}"; then
                    echo "allow ${ip4wl};"
                fi
            done
            
        else # default - allow all
            echo "allow all;"
        fi
        
        # add in a deny all if hte user wanted it
        if [[ "${_addDenyRule}" == "true" ]]; then
            echo "deny all;"
        fi
    } > "${_accessFile}"
    
    return $E_SUCCESS
}


# formats a given filename into the correct format for nginx
function nginx_format_filename() {
    local filename="${1}"
    # swap dots for underscores
    filename=$(echo "${filename}" | tr '.' '_')
    # and slashes for dashes
    filename=$(echo "${filename}" | tr '/' '-')
    
    echo "${filename}"
    return $E_SUCCESS
    
}

# removes an include line from nginx
function nginx_remove_include() {
    local _include=$( regex_escape "${1}" )
    local _file="${2}"
    
    # remove the lines from the file
    if remove_lines_from_file "${_file}" "include ${_include};" "false"; then
        return $E_SUCCESS
    fi
    
    return $E_ERROR
}

# sets up a url with given parameters
function nginx_add_url() {
    local _url="${1}"
    local _urlCert="${2}"
    local _urlWebSocket="${3}"
    local _urlMaxFileSize="${4}"
    local _ip4="${5}"
    local _uuid="${6}"
    local _container_dataset="${7}"
    declare -a _whiteList=("${!8}")
    
    # split up the url into its domain and directory segments
    # check if the url actually contained a /
    if string_contains_char "${_url}" '/'; then
        _urlDomain=$(lcut ${_url} '/')
        _urlDirectory=$(rcut ${_url} '/')
        # add the / back in
        _urlDirectory="/${_urlDirectory}"
    else
        _urlDomain="${_url}"
        _urlDirectory='/'
    fi
    
    # remove any trailing slashes
    #local _filename=$(rtrim "${_url}" '/')
    local _filename=$(rtrim "${_urlDomain}" '/')
    local _upstreamFilename=$( rtrim "${_url}" '/' )

    # format the filename of the file to edit - swap dots for underscores
    _filename=$( nginx_format_filename "${_filename}" )
    _upstreamFilename=$( nginx_format_filename "${_upstreamFilename}" )
    
    # check if this is a ssl url
    if [[ -n "${_urlCert}" ]]; then
        #####################################
        # SET UP THE HTTPS UPSTREAM FILE
        # check if the https upstream file exists
        if [[ ! -f "${NGINX_UPSTREAM_DIR}/https-${_filename}" ]]; then
            # create it
    
            if ! nginx_create_upstream_file "https-${_upstreamFilename}" "${NGINX_UPSTREAM_DIR}/https-${_upstreamFilename}"; then
                e_error "Failed to create HTTP proxy upstream file ${NGINX_UPSTREAM_DIR}/https-${_filename}"
            fi
        fi
        
        # add the ip address to the https upstream block
        nginx_add_to_upstream_block "${NGINX_UPSTREAM_DIR}/https-${_upstreamFilename}" "${_ip4}" "443" "https-${_upstreamFilename}"
        
        # include this file in the dataset for destruction
        zfs_append_custom_array "${_container_dataset}" "${ZFS_PROP_ROOT}.nginx_upstream" "https-${_upstreamFilename}"
        
        #####################################
        # SET UP THE HTTPS SERVER_NAME FILE
        # check if the https server_name file exists
        if [[ ! -f "${NGINX_SERVERNAME_DIR}/https-${_filename}" ]]; then
            # create it
            if ! nginx_create_servername_file "${_urlDomain}" "${NGINX_SERVERNAME_DIR}/https-${_filename}" "${_urlCert}"; then
                e_error "Failed to create HTTPS proxy servername file ${NGINX_SERVERNAME_DIR}/https-${_filename}"
            fi
        fi
        
        # add the location data if it doesnt already exist
        nginx_add_location_block "${_urlDirectory}" "${NGINX_SERVERNAME_DIR}/https-${_filename}" "true"
        # insert the additional location data
        nginx_insert_location_data "https-${_upstreamFilename}" "${_urlDirectory}" "${NGINX_SERVERNAME_DIR}/https-${_filename}" "${_urlWebsocket}" "${_urlMaxFileSize}" "true"
        # include this file in the dataset for destruction
        zfs_append_custom_array "${_container_dataset}" "${ZFS_PROP_ROOT}.nginx_servername" "https-${_filename}"
        
        #####################################
        # SET UP THE HTTP REDIRECT SERVER_NAME FILE
        # check if the https server_name file exists
        if [[ ! -f "${NGINX_SERVERNAME_DIR}/http-${_filename}" ]]; then
            # create it
            if ! nginx_create_servername_file "${_urlDomain}" "${NGINX_SERVERNAME_DIR}/http-${_filename}" ""; then
                e_error "Failed to create HTTP proxy servername file ${NGINX_SERVERNAME_DIR}/http-${_filename}"
            fi
        fi
        
        # add the location data if it doesnt already exist
        nginx_add_location_block "${_urlDirectory}" "${NGINX_SERVERNAME_DIR}/http-${_filename}" "false"
        # insert the redirect
        $(add_line_to_file_between_strings_if_not_exists "location ${_urlDirectory} {" '        return 301 https://$host$request_uri;' "}" "${NGINX_SERVERNAME_DIR}/http-${_filename}")
        # include this file in the dataset for destruction
        zfs_append_custom_array "${_container_dataset}" "${ZFS_PROP_ROOT}.nginx_servername" "http-${_filename}"
        
        # Include the access file for this container in the server_name file
        local _accessFileName=$( nginx_format_filename "${_uuid}" )

        local _accessFilePath="${NGINX_ACCESSFILE_DIR}/${_accessFileName}"
        
        # now create the access file if we received whitelist data
        if [[ ${#_whiteList[@]} -gt 0 ]]; then
            nginx_create_access_file "${_accessFilePath}" _whiteList[@] "true"
            # add a deny all into the server file so that we can reference many allows from includes
            #$(add_line_to_file_after_string "        deny all;" "location ${_urlDirectory} {" "${NGINX_SERVERNAME_DIR}/https-${_filename}")
        
            # and include the access file for this container
            $(add_line_to_file_after_string "        include ${_accessFilePath};" "location ${_urlDirectory} {" "${NGINX_SERVERNAME_DIR}/https-${_filename}");
        fi
    else
        #####################################
        # SET UP THE HTTP UPSTREAM FILE
        # check if the https upstream file exists
        if [[ ! -f "${NGINX_UPSTREAM_DIR}/http-${_filename}" ]]; then
            # create it
            if ! nginx_create_upstream_file "http-${_upstreamFilename}" "${NGINX_UPSTREAM_DIR}/http-${_upstreamFilename}"; then
                e_error "Failed to create HTTP proxy upstream file ${NGINX_UPSTREAM_DIR}/http-${_filename}"
            fi
        fi
        
        # add the ip address to the https upstream block
        nginx_add_to_upstream_block "${NGINX_UPSTREAM_DIR}/http-${_upstreamFilename}" "${_ip4}" "80" "http-${_upstreamFilename}"
        # include this file in the dataset for destruction
        zfs_append_custom_array "${_container_dataset}" "${ZFS_PROP_ROOT}.nginx_upstream" "http-${_upstreamFilename}"
        
        #####################################
        # SET UP THE HTTP SERVER_NAME FILE

        # check if the https server_name file exists
        if [[ ! -f "${NGINX_SERVERNAME_DIR}/http-${_filename}" ]]; then
            # create it
            if ! nginx_create_servername_file "${_urlDomain}" "${NGINX_SERVERNAME_DIR}/http-${_filename}" "${_urlCert}"; then
                e_error "Failed to create HTTP proxy servername file ${NGINX_SERVERNAME_DIR}/http-${_filename}"
            fi
        fi
        
        # add the location data if it doesnt already exist
        nginx_add_location_block "${_urlDirectory}" "${NGINX_SERVERNAME_DIR}/http-${_filename}" "false"
        # insert the additional location data
        nginx_insert_location_data "http-${_upstreamFilename}" "${_urlDirectory}" "${NGINX_SERVERNAME_DIR}/http-${_filename}" "${_urlWebsocket}" "${_urlMaxFileSize}" "false"
        # include this file in the dataset for destruction
        zfs_append_custom_array "${_container_dataset}" "${ZFS_PROP_ROOT}.nginx_servername" "http-${_filename}"
        
        # Include the access file for this container in the server_name file
        local _accessFileName=$( nginx_format_filename "${_uuid}" )
        local _accessFilePath="${NGINX_ACCESSFILE_DIR}/${_accessFileName}"
        
        # now create the access file if we received whitelist data
        if [[ ${#_whiteList[@]} -gt 0 ]]; then
            nginx_create_access_file "${_accessFilePath}" _whiteList[@]
            # add a deny all into the server file so that we can reference many allows from includes
            $(add_line_to_file_after_string "        deny all;" "location ${_urlDirectory} {" "${NGINX_SERVERNAME_DIR}/http-${_filename}")
        
            # and include the access file for this container
            $(add_line_to_file_after_string "        include ${_accessFilePath};" "location ${_urlDirectory} {" "${NGINX_SERVERNAME_DIR}/http-${_filename}");
        fi
    fi
}