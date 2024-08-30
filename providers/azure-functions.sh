#!/bin/bash

AXIOM_PATH="$HOME/.axiom"
LOG="$AXIOM_PATH/log.txt"
resource_group="$(jq -r '.resource_group' "$AXIOM_PATH"/axiom.json)"
subscription_id="$(jq -r '.subscription_id' "$AXIOM_PATH"/axiom.json)"


###################################################################
#  Create Instance is likely the most important provider function :)
#  needed for init and fleet
#
create_instance() {
	name="$1"
	image_id="$2"
	size_slug="$3"
	region="$4"
	boot_script="$5"
    sshkey="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.sshkey')"

	#location="$(az account list-locations | jq -r ".[] | select(.name==\"$region\") | .displayName")"
	location="$region"

  az vm create --resource-group $resource_group --name "$name" --image "$image_id" --location "$location" --size "$size_slug" --tags "$name"=True --os-disk-delete-option delete --data-disk-delete-option delete --nic-delete-option delete --admin-username op --ssh-key-values ~/.ssh/$sshkey.pub >/dev/null 2>&1
	az vm open-port --resource-group $resource_group --name "$name" --port 0-65535 >/dev/null 2>&1 
	sleep 260
}

###################################################################
# deletes instance, if the second argument is set to "true", will not prompt
# used by axiom-rm
#
delete_instance() {
    name="$1"
    force="$2"

    if [ "$force" == "true" ]; then
                # Does not delete all of the related resources like other platforms.
               # az vm delete --name "$name" --resource-group $resource_group --yes --debug
                # recommeded to delete resources by tags instead
                az resource delete --ids $(az resource list --tag "$name"=True -otable --query "[].id" -otsv) >/dev/null 2>&1

                # when deleting a fleet, there is a virtual network left over from the first VM becuse it's used by the others
                # need to figure out how to delete it...
                # It actually left over a public-ip, network security group and the virutal network, and here is the way to do it
                az resource delete --ids $(az network public-ip list --query '[?ipAddress==`null`].[id]' -otsv | grep $name) >/dev/null 2>&1
                az resource delete --ids $(az network nsg list --query "[?(subnets==null) && (networkInterfaces==null)].id" -o tsv | grep $name) >/dev/null 2>&1
                az resource delete --ids $(az network nic list --query '[?virtualMachine==`null` && privateEndpoint==`null`].[id]' -o tsv | grep $name) >/dev/null 2>&1
    
    else
        # az vm delete --name "$name" --resource-group $resource_group
                echo -e -n "  Are you sure you want to delete $name (y/N) - default NO: "
                read ans
                if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
                        echo -e "${Red}...deleting $name...${Color_Off}"
                        az resource delete --ids $(az resource list --tag "$name"=True -otable --query "[].id" -otsv) >/dev/null 2>&1
                fi
    fi
}


###################################################################
# Instances functions
# used by many functions in this file
# takes no arguments, outputs JSON object with instances
instances() {
        az vm list --resource-group $resource_group -d
}

# takes one argument, name of instance, returns raw IP address
# used by axiom-ls axiom-init
instance_ip() {
        name="$1"
        az vm list --resource-group $resource_group  -d | jq -r ".[] | select(.name==\"$name\") | .publicIps"
}

# check if instance name is in .sshconfig
# used by axiom-scan
instance_ip_cache() {
        name="$1"
    config="$2"
    ssh_config="$AXIOM_PATH/.sshconfig"

    if [[ "$config" != "" ]]; then
        ssh_config="$config"
    fi
    cat "$ssh_config" | grep -A 1 "$name" | awk '{ print $2 }' | tail -n 1
}

# used by axiom-select axiom-ls
instance_list() {
         az vm list --resource-group $resource_group | jq -r '.[].name'
}

# used by axiom-ls
instance_pretty() {
	data=$(instances)

	(i=0
	echo '"Instance","IP","Size","Region","Status","$M"'


	echo "$data" | jq -c '.[] | select(.type=="Microsoft.Compute/virtualMachines")' | while IFS= read -r instance;
	do
		name=$(echo $instance | jq -r '.name')
		size=$(echo $instance | jq -r ". | select(.name==\"$name\") | .hardwareProfile.vmSize")
		region=$(echo $instance | jq -r ". | select(.name==\"$name\") | .location")
                power=$(echo $instance | jq -r ". | select(.name==\"$name\") | .powerState")

		csv_data=$(echo $instance | jq ".size=\"$size\"" | jq ".region=\"$region\"" | jq ".powerState=\"$power\"")
		echo $csv_data | jq -r '[.name, .publicIps, .size, .region, .powerState] | @csv'
	done

	echo "\"_\",\"_\",\"_\",\"_\",\"Total\",\"\$$i\"") | column -t -s, | tr -d '"' 

	i=0
}

###################################################################
#  Dynamically generates axiom's SSH config based on your cloud inventory
#  Choose between generating the sshconfig using private IP details, public IP details or optionally lock
#  Lock will never generate an SSH config and only used the cached config ~/.axiom/.sshconfig 
#  Used for axiom-exec axiom-fleet axiom-ssh
#
generate_sshconfig() {
        boxes="$(instances)"
        sshnew="$AXIOM_PATH/.sshconfig.new$RANDOM"
        echo -n "" > "$sshnew"
        echo -e "\tServerAliveInterval 60\n" >> $sshnew
  sshkey="$(cat "$AXIOM_PATH/axiom.json" | jq -r '.sshkey')"
  echo -e "IdentityFile $HOME/.ssh/$sshkey" >> $sshnew

    
        for name in $(echo "$boxes" | jq -r '.[].name')
        do 
                ip=$(echo "$boxes" | jq -r ".[] | select(.name==\"$name\") | .publicIps")
                echo -e "Host $name\n\tHostName $ip\n\tUser op\n\tPort 2266\n" >> $sshnew

        done
        mv $sshnew $AXIOM_PATH/.sshconfig
}

###################################################################
# takes any number of arguments, each argument should be an instance or a glob, say 'omnom*', returns a sorted list of instances based on query
# $ query_instances 'john*' marin39
# Resp >>  john01 john02 john03 john04 nmarin39
# used by axiom-ls axiom-select axiom-fleet axiom-rm axiom-power
#
query_instances() {
        droplets="$(instances)"
        selected=""

        for var in "$@"; do
                if [[ "$var" =~ "*" ]]
                then
                        var=$(echo "$var" | sed 's/*/.*/g')
                        selected="$selected $(echo $droplets | jq -r '.[].name' | grep "$var")"
                else
                        if [[ $query ]];
                        then
                                query="$query\|$var"
                        else
                                query="$var"
                        fi
                fi
        done

        if [[ "$query" ]]
        then
                selected="$selected $(echo $droplets | jq -r '.[].name' | grep -w "$query")"
        else
                if [[ ! "$selected" ]]
                then
                        echo -e "${Red}No instance supplied, use * if you want to delete all instances...${Color_Off}"
                        exit
                fi
        fi

        selected=$(echo "$selected" | tr ' ' '\n' | sort -u)
        echo -n $selected
}

###################################################################
# 
# used by axiom-scan axiom-exec axiom-scp
query_instances_cache() {
        selected=""
    ssh_conf="$AXIOM_PATH/.sshconfig"

        for var in "$@"; do
        if [[ "$var" =~ "-F=" ]]; then
            ssh_conf="$(echo "$var" | cut -d "=" -f 2)"
        elif [[ "$var" =~ "*" ]]; then
                        var=$(echo "$var" | sed 's/*/.*/g')
            selected="$selected $(cat "$ssh_conf" | grep "Host " | awk '{ print $2 }' | grep "$var")"
                else
                        if [[ $query ]];
                        then
                                query="$query\|$var"
                        else
                                query="$var"
                        fi
                fi
        done

        if [[ "$query" ]]
        then
        selected="$selected $(cat "$ssh_conf" | grep "Host " | awk '{ print $2 }' | grep -w "$query")"
        else
                if [[ ! "$selected" ]]
                then
                        echo -e "${Red}No instance supplied, use * if you want to delete all instances...${Color_Off}"
                        exit
                fi
        fi

        selected=$(echo "$selected" | tr ' ' '\n' | sort -u)
        echo -n $selected
}

###################################################################
#
# used by axiom-fleet axiom-init
get_image_id() {
        query="$1"
        images=$(az image list --resource-group $resource_group)
        name=$(echo $images | jq -r ".[].name" | grep -wx "$query" | tail -n 1)
        id=$(echo $images |  jq -r ".[] | select(.name==\"$name\") | .id")
        echo $id
}

###################################################################
# Manage snapshots
# used for axiom-images
#
snapshots() {
        az image list --resource-group $resource_group
}

# axiom-images
get_snapshots() {
        az image list --output table --resource-group $resource_group
}

# Delete a snapshot by its name
# axiom-images
delete_snapshot() {
        name="$1"       
        az image delete --name "$name" --resource-group $resource_group
}

###################################################################
# Get data about regions
# used by axiom-regions
list_regions() {
    az account list-locations | jq -r '.[].name'
}

regions() {
        az account list-locations
}

###################################################################
#  Manage power state of instances
#  Used for axiom-power
#
poweron() {
instance_name="$1"
az vm start -g ${resource_group} -name $instance_name --resource-group $resource_group
}

# axiom-power
poweroff() {
instance_name="$1"
az vm stop -g ${resource_group} --name  $instance_name --resource-group $resource_group
}

# axiom-power
reboot(){
instance_name="$1"
az vm restart -g ${resource_group} --name $instance_name --resource-group $resource_group
}

# axiom-power
instance_id() {
        name="$1"
        az vm list --resource-group $resource_group | jq -r ".[] | select(.name==\"$name\") | .id"
}

###################################################################
#  List available instance sizes
#  Used by ax sizes
#
sizes_list() {
region="$(jq -r '.region' "$AXIOM_PATH"/axiom.json)"
(
  # Print the headers
  echo -e "InstanceType\tCores\tMemory"

  # Fetch and process VM sizes, sort them, and output the results
  az vm list-sizes --location $region --query "[].{Name:name, Cores:numberOfCores, Memory:memoryInMB}" --output json |
    jq -r '.[] | "\(.Name)\t\(.Cores)\t\(.Memory)"' |
    sort -n -k2,2 -k3,3
) |
# Format the output with correct column alignment
awk -F'\t' '{printf "%-20s %-10s %-10s\n", $1, $2, $3}'

}
