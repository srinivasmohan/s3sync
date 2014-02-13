S3 Sync
=======

Scenario: Have a large S3 bucket that you want to sync to another bucket.

Typical Solutions -
Use s3cmd / s3sync sort of tools - These worked very well for smaller buckets but not for large ones (with 300000+ objects) as they appeared to run one object at a time... Hence this ruby script. (s3cmd was done with about 20000 objects after having run from a ec2 instance for over 20 hours!)

With this Jruby based script, I could get my ~300000 objects bucket (approx 450GB of objects) synced from a US West (oregon only) bucket synced to:
* A US Standard bucket in under 4 hours.
* A EU (Ireland) bucket in about 6 hours. (On a different note, that means AWS pushed 75GB/hour i.e. ~200Mbps or higher from US-EU - Dedicated links for AWS use alone?)

And subsequent syncs (every hour) run in under 10 minutes. The code could do with a lot of cleanup but the gist is when copying between S3 buckets under the same account, its best to use S3 `copy_to` rather than fetch and upload each object - See [S3Object copy_to](http://docs.aws.amazon.com/AWSRubySDK/latest/AWS/S3/S3Object.html#copy_to-instance_method) for details.

Related blog article [Sync S3 buckets in parallel mode via concurrent threads](http://www.onepwr.org/2014/02/12/sync-s3-buckets-in-parallel-mode-via-concurrent-threads/)

Caveats
=======

This is code written by a sysad to run quick :-)

You could sync in two modes, based on -
* Existence of keys (compare list of keys on src vs keys on destination buckets and ONLY copy objects that exist on Source but not at Destination)
* Use the Etag of objects at Src and Dest to compare and push if Etag is different.

The former is very quick if you run it frequently enough - In my case, objects pushed to S3 never get changed so this works for me. However there may be cases where the S3 object may be modified too. The Etag comparison comes handy then as it does a copy if the key does'nt exist on Destination and also copies if the content-length/etag are different.

Keep in mind that for most cases, the Etag returned by S3 for an object is equivalent to the objects md5sum - However this is not true for multi-part uploads. (If the etag has a '-' followed by some number that was a mutipart upload). So comparing Etag for multipart upload files does'nt make sense. Most of my object are under 400MB so I set `:s3_multipart_threshold` to 400MB - YMMV. Updating a S3 object (e.g. add a tag) forces S3 to recompute the Etag for that object so thats a crude way to have the Etag for a multi-part uploaded object changed to its true md5sum. However S3 only guarantees the presence of an Etag - no promises that this needs to be a md5sum, so that may very well change.

Also, AWS charges for S3 access from outside EC2... If I were to run a normal fetch/upload inside EC2 to S3 it should ideally cost me nothing (except performance). Use of `copy_to` means this happens internally with S3 itself making the client fetch/upload not necessary - Not sure how/if you would get billed for that. 

Setup
=====

I needed to be able to run multiple threads concurrently to speed up the sync process (My use case for this was to backup a US bucket to EU and vice versa to minimize local latency and not have to come across the pond). Due to Ruby MRI / Pythons [GIL mechanism](http://en.wikipedia.org/wiki/Global_Interpreter_Lock), running parallel threads with stock Ruby was'nt possible so I picked Jruby (Code in Ruby but run in JVM).

My test boxes were Ubuntu so your setup may vary slightly:

```
apt-get install openjdk-7-jdk openjdk-7-jre openjdk-7-jre-headless openjdk-7-jre-lib
cd /opt && wget http://jruby.org.s3.amazonaws.com/downloads/1.7.10/jruby-bin-1.7.10.tar.gz
tar zxvf jruby-bin-1.7.10.tar.gz
export PATH=/opt/jruby-1.7.10/bin:$PATH

root@wh1-use:~/parallel-s3sync# jruby -v
jruby 1.7.10 (1.9.3p392) 2014-01-09 c4ecd6b on OpenJDK 64-Bit Server VM 1.7.0_51-b00 [linux-amd64]

#Get the aws-sdk gem installed.
jruby -S gem install aws-sdk

#Check
root@wh1-use:~/parallel-s3sync# jruby -S gem list --local | grep aws-sdk
aws-sdk (1.33.0)


```


Sample Config
=============

Script expects `s3auth.yml` in the same folder as the script.

```

---
aws_key: YOURKEY
aws_secret: YOURSECRET
s3src:
- YOUR_USWEST_BUCKET
- s3-us-west-2.amazonaws.com
s3dest:
- YOUR_DST_BUCKET
- s3.amazonaws.com
prefix: uploads
usemd5: true

```

Where -
* `s3src` and `s3dest` are arrays of `['BUCKETNAME','bucket-endpoint']` - Bucket endpoints as listed in [AWS Docs](http://docs.aws.amazon.com/general/latest/gr/rande.html#s3_region)
* `prefix` - Is the toplevel prefix to sync from Source to Destination buckets
* `usemd5` - Is true/false - When false, simply copy keys in SRC but not in DST to DST. When True also look at etag/content length from a `HEAD` on the objects.

Then run `nohup /pathto/s3sync.rb &` and thats it!

