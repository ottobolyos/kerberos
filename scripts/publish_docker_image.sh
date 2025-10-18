#!/usr/bin/env bash

# Build a multi-arch Docker image and optionally publish it to Docker Hub
#
# Exit codes:
# 0 - Success
# 1 - Invalid command line arguments
# 2 - Missing required environment variables
# 3 - Missing required credentials
# 4 - Bitwarden authentication failed
# 5 - Docker login failed

set -euo pipefail

# Default values
containers=('kerberos')
docker_password=''
docker_username=''
# Note: Dockerfiles can be provided as absolute paths or relative to the script's parent folder.
# Note: Context will be the parent folder of each Dockerfile.
dockerfiles=('kerberos.dockerfile')
platforms=('linux/amd64')
push_image='false'
use_bw='false'

# Generate a container list for the help message
generate_container_list() {
	local result=''
	local count="${#containers[@]}"

	for ((i = 0; i < count; i++)); do
		if [ "$i" -eq 0 ]; then
			result="ladder99/${containers[$i]}"
		elif [ "$i" -eq "$((count - 1))" ]; then
			result="$result and ladder99/${containers[$i]}"
		else
			result="$result, ladder99/${containers[$i]}"
		fi
	done

	echo "$result"
}

# Usage function
usage() {
	cat << EOF
Usage: $0 [OPTIONS]

Build multi-arch Docker images for $(generate_container_list)

OPTIONS:
    -a, --platform PLATFORMS  Comma-separated list of platforms (default: linux/amd64,linux/arm64)
    -b, --use-bw              Use Bitwarden CLI for credentials (requires BW_SESSION env var)
    -d, --push                Push the image to Docker Hub (default: local build only)
    -h, --help                Show this help message
    -p, --password PASS       Docker Hub password (required if not using --use-bw)
    -u, --username USER       Docker Hub username (required if not using --use-bw)

Examples:
    $0                     # Build only, no push
    $0 -db                 # Build and push using Bitwarden (combined flags)
    $0 -d -b               # Build and push using Bitwarden (separate flags)
    $0 --push --use-bw     # Build and push using Bitwarden (long form)
    $0 -dbu user -p pass   # Build and push with Bitwarden + fallback credentials
    $0 -du user -p pass    # Build and push with credentials (combined flags)
    $0 -dba linux/amd64    # Build and push with Bitwarden for single platform
EOF
}

# Parse command line arguments
parse_combined_opts() {
	local opts="$1"
	local arg="$2"
	local i
	local last_opt=''

	for ((i = 1; i < "${#opts}"; i++)); do
		local opt="${opts:$i:1}"
		last_opt="$opt"

		# Handle flags that don't need arguments
		case $opt in
			d) push_image='true'; continue ;;
			b) use_bw='true'; continue ;;
			h) usage; exit 0 ;;
		esac

		# Handle options that need arguments (only allowed as the last option)
		if [ $i -eq $((${#opts} - 1)) ]; then
			case $opt in
				u)
					if [ -z "$arg" ]; then
						echo 'Option -u requires an argument' >&2
						exit 1
					fi
					docker_username="$arg"
					return 1  # Signal that we consumed the next argument
					;;
				p)
					if [ -z "$arg" ]; then
						echo 'Option -p requires an argument' >&2
						exit 1
					fi
					docker_password="$arg"
					return 1  # Signal that we consumed the next argument
					;;
				a)
					if [ -z "$arg" ]; then
						echo 'Option -a requires an argument' >&2
						exit 1
					fi
					IFS=',' read -ra platforms <<< "$arg"
					return 1  # Signal that we consumed the next argument
					;;
				*)
					echo "Unknown option: -$opt" >&2
					usage >&2
					exit 1
					;;
			esac
		else
			# Options with arguments can only be at the end
			case $opt in
				u|p|a)
					echo "Option -$opt requires an argument and must be the last in a combined option" >&2
					exit 1
					;;
				*)
					echo "Unknown option: -$opt" >&2
					usage >&2
					exit 1
					;;
			esac
		fi
	done
	return 0  # Signal that we didn't consume the next argument
}

while [[ $# -gt 0 ]]; do
	case $1 in
		--push)
			push_image='true'
			shift
			;;
		--use-bw)
			use_bw='true'
			shift
			;;
		--username)
			if [ $# -lt 2 ]; then
				echo 'Option --username requires an argument' >&2
				exit 1
			fi
			docker_username="$2"
			shift 2
			;;
		--password)
			if [ $# -lt 2 ]; then
				echo 'Option --password requires an argument' >&2
				exit 1
			fi
			docker_password="$2"
			shift 2
			;;
		--platform)
			if [ $# -lt 2 ]; then
				echo 'Option --platform requires an argument' >&2
				exit 1
			fi
			IFS=',' read -ra platforms <<< "$2"
			shift 2
			;;
		--help)
			usage
			exit 0
			;;
		-h)
			usage
			exit 0
			;;
		-u)
			if [ $# -lt 2 ]; then
				echo 'Option -u requires an argument' >&2
				exit 1
			fi
			docker_username="$2"
			shift 2
			;;
		-p)
			if [ $# -lt 2 ]; then
				echo 'Option -p requires an argument' >&2
				exit 1
			fi
			docker_password="$2"
			shift 2
			;;
		-a)
			if [ $# -lt 2 ]; then
				echo 'Option -a requires an argument' >&2
				exit 1
			fi
			IFS=',' read -ra platforms <<< "$2"
			shift 2
			;;
		-d)
			push_image='true'
			shift
			;;
		-b)
			use_bw='true'
			shift
			;;
		-*)
			# Handle combined short options
			if [[ "$1" =~ ^-[dbhaup]+$ ]]; then
				if parse_combined_opts "$1" "${2:-}"; then
					shift  # Only consumed the option, not the argument
				else
					shift 2  # Consumed both option and argument
				fi
			else
				echo "Unknown option: $1" >&2
				usage >&2
				exit 1
			fi
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done

# Validate arrays have the same length
if [ ${#containers[@]} -ne ${#dockerfiles[@]} ]; then
	echo 'Error: containers and dockerfiles arrays must have the same number of elements' >&2
	exit 2
fi

# Validate Bitwarden usage
if [ "$use_bw" = true ]; then
	if [ -z "$BW_SESSION" ]; then
		echo 'Error: BW_SESSION environment variable must be set when using --use-bw' >&2
		exit 2
	fi
fi

# Validate credentials if pushing
if [ "$push_image" = true ]; then
	if [ "$use_bw" = false ]; then
		# When not using Bitwarden, a username and password are required
		if [ -z "$docker_username" ] || [ -z "$docker_password" ]; then
			echo 'Error: -u/--username and -p/--password are required when using -d/--push without -b/--use-bw' >&2
			exit 3
		fi
	fi

	# When using `--use-bw`, username/password are optional (they are used as a fallback when specified)
fi

# Set `docker build` options
if [ "$push_image" = true ]; then
	docker_build_options='--push'
	platform_arg="--platform $(IFS=','; echo "${platforms[*]}")"
else
	docker_build_options='--load'
	# For local builds, omit `--platform` to let Docker auto-detect the host platform
	platform_arg=''
fi

# Get the Docker Hub credentials from Bitwarden if needed
if [ "$push_image" = true ] && [ "$use_bw" = true ]; then
	if ! bw_data="$(bw get item 2060f454-b2a5-4878-a77d-ad1b00bf19ab 2>/dev/null)"; then
		echo 'Warning: Failed to get credentials from Bitwarden' >&2
		if [ -n "$docker_username" ] && [ -n "$docker_password" ]; then
			echo 'Warning: Falling back to provided credentials' >&2
		else
			echo 'Error: Bitwarden failed and no fallback credentials provided' >&2
			exit 4
		fi
	else
		docker_username="$(jq -r .login.username <<< "$bw_data")"
		docker_password="$(jq -r .login.password <<< "$bw_data")"
		unset bw_data
	fi
fi

# Run QEMU hypervisor in a Docker container which enables execution of different multi-architecture containers by QEMU 1 and `binfmt_misc`
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# Remove `l99builder` if it exists
docker buildx rm l99builder || true

# Create new `l99builder`
docker buildx create --name l99builder --driver docker-container --use

# Inspect the current builder instance
docker buildx inspect --bootstrap

# Get the current git tag for versioning
git_tag="$(git describe --always)"


# Log into Docker Hub if pushing
if [ "$push_image" = 'true' ]; then
	if ! docker login -u "$docker_username" --password-stdin <<< "$docker_password" 2>/dev/null; then
		echo 'Error: Docker login failed with provided credentials' >&2
		exit 5
	fi
	unset docker_username
	unset docker_password
fi

# Build multi-arch Docker images for both frontend and backend
for i in "${!containers[@]}"; do
  container="${containers[$i]}"
  dockerfile_path="$(realpath "${dockerfiles[$i]}")"
  context_path="$(dirname "$dockerfile_path")"

  echo "Building $container..."

  # Build the image
  # Note: `docker_build_options` needs to be unquoted, otherwise when it is set to an empty string, `docker buildx build` errors out with `ERROR: "docker buildx build" requires exactly 1 argument.` (this is a Bash feature, as a quoted empty string evaluates to a defined argument).
  # shellcheck disable=SC2086 # `$platform_arg` and `$docker_build_options` must be split
  docker buildx build \
    $platform_arg \
    --build-arg GIT_COMMIT="$git_tag" \
    --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ')" \
    -f "$dockerfile_path" \
    -t "ladder99/$container:latest" \
    -t "ladder99/$container:$git_tag" \
    $docker_build_options \
    "$context_path"
done

# Log out from Docker Hub if we logged in
if [ "$push_image" = 'true' ]; then
	docker logout
fi
