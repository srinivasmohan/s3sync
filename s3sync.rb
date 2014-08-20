#!/opt/jruby/bin/jruby

require "rubygems"
require "yaml"
require "json"
require "aws-sdk"

require "java"
java_import 'java.util.concurrent.Callable'
java_import 'java.util.concurrent.FutureTask'
java_import 'java.util.concurrent.LinkedBlockingQueue'
java_import 'java.util.concurrent.ThreadPoolExecutor'
java_import 'java.util.concurrent.TimeUnit'

#MAXTHREADS=20 - defaults to 25 now. or override in config.

def logmsg(msg)
	puts "#{Time.now.strftime('%Y%m%d.%H:%M:%S')} - #{msg}" unless msg.nil?
end

def getlist(bucket,prefixstr)
	logmsg("Fetching object list from bucket #{bucket.name} (Prefix #{prefixstr})")
	objlist=Hash.new
	size=0
	bucket.objects.with_prefix(prefixstr).each do |x|
		objlist[x.key]=nil
	end
	logmsg("#{bucket.name} (Prefix #{prefixstr}) => #{objlist.keys.length} items")
	objlist
end

def getattrib(obj)
	attribhash={}
	begin
		obj.head.delete_if{ |k,v| !(k==:etag || k==:content_length)}.each_pair {|k,v| attribhash[k]=v }	
	rescue AWS::S3::Errors::NoSuchKey => e	
		attribhash={}
	end	
	attribhash
end

def copy(srcb,dstb,keylist,usemd5=false) #keylist is array of [key,obj.head]
	return "NothingToDo" unless keylist.length>0
	count=keylist.length
	synced=0	
	tosync=0
	keylist.each do |y|
		key=y[0]
		srcobj=srcb.objects[key]
		srchead=getattrib(srcobj)
		reason="missing-at-dst"
		ifCopy=false
		if usemd5
			dstobj=dstb.objects[key]
			dsthead=getattrib(dstobj)
			ifMissing=(dsthead.keys.length==0) ? true: false
			sizechanged=srchead.has_key?(:content_length) && dsthead.has_key?(:content_length) && srchead[:content_length].to_i!=dsthead[:content_length].to_i
			noMatch=dsthead.has_key?(:etag) && srchead.has_key?(:etag) && dsthead[:etag]!=srchead[:etag] && sizechanged ? true: false
			ifCopy=(ifMissing || noMatch)
			reason="md5-mismatch src:#{srchead[:etag]} dst:#{dsthead[:etag]}" if noMatch
		else #If we were called with usemd5=false, we were already suppiled a list of keys on src but not in dst. So copy.
			ifCopy=true
		end	
		#logmsg("RAW|#{key}|#{srchead[:content_length]}|#{srchead[:etag]}")
		next unless ifCopy
		#logmsg("TO-COPY: #{key} [#{reason}] #{srchead[:content_length]}Bytes")
		tosync+=1
		size=srchead[:content_length]
		begin	
			srcobj.copy_to(key, {:bucket => dstb})
		rescue Exception => e
			logmsg("Key: #{key}, Reason=[#{reason}], Error: #{e.inspect}")
			next
		end
		synced+=1		
		logmsg("Key: #{key} Reason=[#{reason}], Copied OK (#{size} Bytes)") 
	end
	return (tosync > 0 ? "Synced #{synced}/#{usemd5 ? tosync : count} objects":"NothingToDo - NO sync'able objects")
end

Conffile=File.dirname(__FILE__)+"/s3auth.yml"

class Syncer
	include Callable

	def initialize(srcb,dstb,objlist,usemd5=false)
		@srcb=srcb
		@dstb=dstb
		@list=objlist
		@usemd5=usemd5
	end
	
	def call
		retstr=nil
		begin
			retstr="ThreadFinished: "+copy(@srcb,@dstb,@list,@usemd5)
		rescue Exception => e
			retstr="ThreadError: #{e.inspect}"
		ensure
			logmsg(retstr)
		end
	end

end

begin
  confighash=YAML::load(File.open(Conffile))
rescue Exception => e
  abort "Could not parse YAML file (#{Conffile}) - #{e.inspect}"
end

src=confighash['s3src'][0]
dest=confighash['s3dest'][0]
logmsg("START: Sync from bucket #{src} [#{confighash['s3src'][1]}] TO #{dest} [#{confighash['s3dest'][1]}]")
AWS.config({
  :region => 'us-west-2',
	:use_ssl => false, #no ssl maybe faster?
	:s3_multipart_threshold => 400*1024*1024 #No multipart uploads for objects under this size - Etag gets messy when multipart uploads are done :(
})

usemd5=confighash.has_key?('usemd5') && confighash['usemd5'] ? true: false
logmsg("Comparison: MD5 sums WILL #{usemd5 ? '': 'NOT'} BE compared! - Use of md5sums/etags is slower but safer!!!")
s3svc1=AWS::S3.new(:access_key_id => confighash['aws_key'], :secret_access_key => confighash['aws_secret'], :s3_endpoint => confighash['s3src'][1])
s3svc2=AWS::S3.new(:access_key_id => confighash['aws_key'], :secret_access_key => confighash['aws_secret'], :s3_endpoint => confighash['s3dest'][1])

srcbucket=s3svc1.buckets[src]
dstbucket=s3svc2.buckets[dest]

srclist=getlist(srcbucket,confighash['prefix'])

if !usemd5 #Filter by existence alone
	dstlist=getlist(dstbucket,confighash['prefix'])
	srclist.keys.each do |x|
		srclist.delete(x) if dstlist.has_key?(x)		
	end
	logmsg("PruneList: No-MD5-Check - SRC has #{srclist.keys.length} item(s) to sync to DST")
else
	logmsg("PruneList: MD5-Check - SRC has #{srclist.keys.length} item(s) - Each will be checked against DST for md5/etag")
end

if srclist.keys.length==0
	logmsg("ENDED: Nothing to sync!")
	exit 0
end
copyobjects=srclist.keys.each.map { |x| [ x, srclist[x]] }
MAXTHREADS=confighash.has_key?('maxthreads') ? confighash['maxthreads'] : 25 
tsnow=Time.now
numObjectsPerThread=(copyobjects.length<= MAXTHREADS) ? copyobjects.length : copyobjects.length/MAXTHREADS
brokenUp=copyobjects.each_slice(numObjectsPerThread).to_a
thrct=brokenUp.length

logmsg("START: Sync via #{thrct} threads with upto #{numObjectsPerThread} objects per thread.")
#Executor pool 
executor = ThreadPoolExecutor.new(
	MAXTHREADS, # #pool_treads
	MAXTHREADS, # max pool_threads
	60, # keep idle threads for this long before killing them
	TimeUnit::SECONDS,
	LinkedBlockingQueue.new
)

allSyncJobs=[]
brokenUp.length.times do |i|
	logmsg("Spawning sync thread #{i+1}/#{thrct}") if ( (i+1)%10==0 || (i+1)==thrct )
	thisjob=FutureTask.new( Syncer.new(srcbucket,dstbucket,brokenUp[i],usemd5) )
	executor.execute(thisjob)
	allSyncJobs << thisjob	
end

allSyncJobs.each do |t|
	t.get
end

logmsg("ENDED: Sync completed (Check-MD5=#{usemd5}) in #{(Time.now-tsnow).round(3)}secs")
executor.shutdown()

