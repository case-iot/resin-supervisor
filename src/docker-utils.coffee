Docker = require 'dockerode'
Promise = require 'bluebird'
{ spawn } = require 'child_process'
progress = require 'request-progress'
config = require './config'
JSONStream = require 'JSONStream'
es = require 'event-stream'
_ = require 'lodash'
knex = require './db'

{ request } = require './request'

docker = Promise.promisifyAll(new Docker(socketPath: config.dockerSocket))
# Hack dockerode to promisify internal classes' prototypes
Promise.promisifyAll(docker.getImage().constructor.prototype)
Promise.promisifyAll(docker.getContainer().constructor.prototype)

exports.docker = docker

# Create an array of (repoTag, image_id, created) tuples like the output of `docker images`
listRepoTagsAsync = ->
	docker.listImagesAsync()
	.then (images) ->
		images = _.sortByOrder(images, 'Created', [ false ])
		ret = []
		for image in images
			for repoTag in image.RepoTags
				ret.push [ repoTag, image.Id, image.Created ]
		return ret

# Find either the most recent image of the same app or the image of the supervisor
findSimilarImage = (repoTag) ->
	application = repoTag.split('/')[1]

	listRepoTagsAsync()
	.then (repoTags) ->
		# Find the most recent image of the same application
		for repoTag in repoTags
			otherApplication = repoTag[0].split('/')[1]
			if otherApplication is application
				return repoTag

		# Otherwise return the most specific supervisor tag (commit hash)
		for repoTag in repoTags when /resin\/.*-supervisor.*:[0-9a-f]{6}/.test(repoTag)
			return repoTag

		return config.supervisorImage

exports.rsyncImageWithProgress = (imgDest, onProgress) ->
	findSimilarImage(imgDest)
	.spread (imgSrc) ->
		rsyncDiff = new Promise (resolve, reject) ->
			console.log("#{config.deltaHost}/api/v1/delta?src=#{imgSrc}&dest=#{imgDest}", timeout: 5 * 60 * 1000)
			progress request.get("#{config.deltaHost}/api/v1/delta?src=#{imgSrc}&dest=#{imgDest}", timeout: 5 * 60 * 1000)
			.on 'progress', onProgress
			.on 'end', ->
				onProgress(percent: 100)
			.on 'response', (res) ->
				if res.statusCode isnt 200
					reject()
				else
					resolve(res)
			.on 'error', reject
			.pause()

		imageConfig = request.getAsync("#{config.deltaHost}/api/v1/config?image=#{imgDest}", {json: true, timeout: 0})
		.spread ({statusCode}, imageConfig) ->
			if statusCode isnt 200
				throw new Error("Invalid configuration: #{imageConfig}")
			return imageConfig

		return [ rsyncDiff, imageConfig, imgSrc ]
	.spread (rsyncDiff, imageConfig, imgSrc) ->
		new Promise (resolve, reject) ->
			dockersync = spawn('/app/src/dockersync.sh', [ imgSrc, imgDest, JSON.stringify(imageConfig) ], stdio: [ 'pipe', 'ignore', 'ignore' ])
			.on 'error', reject
			.on 'exit', (code, signal) ->
				if code isnt 0
					reject(new Error("rsync exited. code: #{code} signal: #{signal}"))
				else
					resolve()

			rsyncDiff.pipe(dockersync.stdin)
			rsyncDiff.resume()

do ->
	# Keep track of the images being fetched, so we don't clean them up whilst fetching.
	imagesBeingFetched = 0
	fetchImage = (image) ->
		imagesBeingFetched++
		docker.createImageAsync(fromImage: image)
		.then (stream) ->
			return new Promise (resolve, reject) ->
				if stream.headers['content-type'] is 'application/json'
					stream.pipe(JSONStream.parse('error'))
					.pipe(es.mapSync(reject))
				else
					stream.pipe es.wait (error, text) ->
						if error
							reject(text)

				stream.on('end', resolve)
		.finally ->
			imagesBeingFetched--

	# Pull docker image returning a stream that reports progress
	# This is less safe than fetchImage and shouldnt be used for supervisor updates
	exports.fetchImageWithProgress = (image, onProgress) ->
		imagesBeingFetched++
		Promise.join(
			docker.pullAsync(image)
			pullProgress(image, onProgress)
			(stream, onProgress) ->
				Promise.fromNode (callback) ->
					docker.modem.followProgress(stream, callback, onProgress)
		)
		.finally ->
			imagesBeingFetched--

	supervisorTag = config.supervisorImage
	if !/:/g.test(supervisorTag)
		# If there is no tag then mark it as latest
		supervisorTag += ':latest'
	exports.cleanupContainersAndImages = ->
		Promise.join(
			knex('app').select()
			.map (app) ->
				app.imageId + ':latest'
			docker.listImagesAsync()
			(apps, images) ->
				imageTags = _.map(images, 'RepoTags')
				supervisorTags = _.filter imageTags, (tags) ->
					_.contains(tags, supervisorTag)
				appTags = _.filter imageTags, (tags) ->
					_.any tags, (tag) ->
						_.contains(apps, tag)
				supervisorTags = _.flatten(supervisorTags)
				appTags = _.flatten(appTags)
				return { images, supervisorTags, appTags }
		)
		.then ({ images, supervisorTags, appTags }) ->
			# Cleanup containers first, so that they don't block image removal.
			docker.listContainersAsync(all: true)
			.filter (containerInfo) ->
				# Do not remove user apps.
				if _.contains(appTags, containerInfo.Image)
					return false
				if !_.contains(supervisorTags, containerInfo.Image)
					return true
				return containerHasExited(containerInfo.Id)
			.map (containerInfo) ->
				docker.getContainer(containerInfo.Id).removeAsync()
				.then ->
					console.log('Deleted container:', containerInfo.Id, containerInfo.Image)
				.catch (err) ->
					console.log('Error deleting container:', containerInfo.Id, containerInfo.Image, err)
			.then ->
				# And then clean up the images, as long as we aren't currently trying to fetch any.
				return if imagesBeingFetched > 0
				imagesToClean = _.reject images, (image) ->
					_.any image.RepoTags, (tag) ->
						return _.contains(appTags, tag) or _.contains(supervisorTags, tag)
				Promise.map imagesToClean, (image) ->
					Promise.map image.RepoTags.concat(image.Id), (tag) ->
						docker.getImage(tag).removeAsync()
						.then ->
							console.log('Deleted image:', tag, image.Id, image.RepoTags)
						.catch (err) ->
							console.log('Error deleting image:', tag, image.Id, image.RepoTags, err)

	containerHasExited = (id) ->
		docker.getContainer(id).inspectAsync()
		.then (data) ->
			return not data.State.Running

	# Return true if an image exists in the local docker repository, false otherwise.
	imageExists = (imageId) ->
		image = docker.getImage(imageId)
		image.inspectAsync().then ->
			return true
		.catch (e) ->
			return false

	# Get the id of an image on a given registry and tag.
	getImageId = (registry, imageName, tag = 'latest') ->
		request.getAsync("http://#{registry}/v1/repositories/#{imageName}/tags")
		.spread (res, data) ->
			if res.statusCode == 404
				throw new Error("No such image #{imageName} on registry #{registry}")
			if res.statusCode >= 400
				throw new Error("Failed to get image tags of #{imageName} from #{registry}. Status code: #{res.statusCode}")
			tags = JSON.parse(data)
			if !tags[tag]?
				throw new Error("Could not find tag #{tag} for image #{imageName}")
			return tags[tag]

	# Return the ids of the layers of an image.
	getImageHistory = (registry, imageId) ->
		request.getAsync("http://#{registry}/v1/images/#{imageId}/ancestry")
		.spread (res, data) ->
			if res.statusCode >= 400
				throw new Error("Failed to get image ancestry of #{imageId} from #{registry}. Status code: #{res.statusCode}")
			history = JSON.parse(data)
			return history

	# Return the number of bytes docker has to download to pull this image (or layer).
	# If the image is already downloaded, then 0 is returned.
	getImageDownloadSize = (registry, imageId) ->
		imageExists(imageId)
		.then (exists) ->
			if exists
				return 0
			request.getAsync("http://#{registry}/v1/images/#{imageId}/json")
			.spread (res, data) ->
				if res.statusCode >= 400
					throw new Error("Failed to get image download size of #{imageId} from #{registry}. Status code: #{res.statusCode}")
				return parseInt(res.headers['x-docker-size'])

	# Get download size of the layers of an image.
	# The object returned has layer ids as keys and their download size as values.
	# Download size is the size that docker will download if the image will be pulled now.
	# If some layer is already downloaded, it will return 0 size for that layer.
	getLayerDownloadSizes = (image, tag = 'latest') ->
		{registry, imageName} = getRegistryAndName(image)
		imageSizes = {}
		getImageId(registry, imageName, tag)
		.then (imageId) ->
			getImageHistory(registry, imageId)
		.map (layerId) ->
			getImageDownloadSize(registry, layerId).then (size) ->
				imageSizes[layerId] = size
		.return(imageSizes)

	# Return percentage from current completed/total, handling edge cases.
	# Null total is considered an unknown total and 0 percentage is returned.
	calculatePercentage = (completed, total) ->
		if not total?
			percentage = 0 # report 0% if unknown total size
		else if total is 0
			percentage = 100 # report 100% if 0 total size
		else
			percentage = (100 * completed) // total
		return percentage

	# Separate string containing registry and image name into its parts.
	# Example: registry.staging.resin.io/resin/rpi
	#          { registry: "registry.staging.resin.io", imageName: "resin/rpi" }
	getRegistryAndName = (image) ->
		[ m, registry, imageName ] = image.match(/(.+[:.].+)\/(.+\/.+)/)
		if not registry
			throw new Error('Expected image name to include registry domain name')
		if not imageName
			throw new Error('Invalid image name, expected domain.tld/repo/image format.')
		return {registry, imageName}

	# Create a stream that transforms `docker.modem.followProgress` onProgress events
	# to include total progress metrics.
	pullProgress = (image, onProgress) ->
		getLayerDownloadSizes(image).then (layerSizes) ->
			currentSize = 0
			completedSize = 0
			totalSize = _.sum(layerSizes)
			return (pull) ->
				if pull.status == 'Downloading'
					currentSize = pull.progressDetail.current
				else if pull.status == 'Download complete'
					shortId = pull.id
					longId = _.find(_.keys(layerSizes), (id) -> id.indexOf(shortId) is 0)
					if longId?
						completedSize += layerSizes[longId]
						currentSize = 0
						layerSizes[longId] = 0 # make sure we don't count this layer again
					else
						console.log 'Progress error: Unknown layer ' + id + ' downloaded by docker. Progress not correct.'
						totalSize = null
				downloadedSize = completedSize + currentSize
				percent = calculatePercentage(downloadedSize, totalSize)

				onProgress({ downloadedSize, totalSize, percent })
