module diskuto.backends.mongodb;

import diskuto.backend;
import vibe.data.bson;
import vibe.db.mongo.mongo;
import vibe.inet.url;

import std.algorithm.iteration : map;
import std.array : array;
import std.exception : enforce;


class MongoDBCommentStore : DiskutoCommentStore {
@trusted: // FIXME! vibe.d < 0.8.0 is not annotated with @safe
	private {
		MongoCollection m_comments;
	}

	this(string database_url)
	{
		MongoClientSettings settings;
		enforce(parseMongoDBUrl(settings, database_url), "Failed to parse MongoDB URL.");
		auto db = connectMongoDB(settings).getDatabase(settings.database);
		m_comments = db["comments"];

		// upgrade "author" field name
		foreach (c; m_comments.find(["userID": ["$exists": true]], ["userID": true]))
			m_comments.update(["_id": c["_id"]], ["$unset": ["userID": Bson(null)], "$set": ["author": c["userID"]]]);
		// upgrade missing "clientAddress" field name
		m_comments.update(["clientAddress": ["$exists": false]], ["$set": ["clientAddress": ""]], UpdateFlags.multiUpdate);
		// upgrade old status field
		m_comments.update(["status": cast(int)CommentStatus.active], ["$set": ["status": "active"]], UpdateFlags.multiUpdate);
		m_comments.update(["status": cast(int)CommentStatus.disabled], ["$set": ["status": "disabled"]], UpdateFlags.multiUpdate);
	}

	StoredComment.ID postComment(StoredComment comment)
	{
		auto mc = MongoStruct!StoredComment(comment);
		mc._id = BsonObjectID.generate();
		m_comments.insert(mc);
		return mc._id.toString();
	}

	StoredComment getComment(StoredComment.ID comment)
	{
		return cast(StoredComment)m_comments.findOne!(MongoStruct!StoredComment)(["_id": BsonObjectID.fromString(comment)]);
	}

	void setCommentStatus(StoredComment.ID id, CommentStatus status)
	{
		import std.conv : to;
		m_comments.update(["_id": BsonObjectID.fromString(id)], ["$set": ["status": status.to!string]]);
	}

	void editComment(StoredComment.ID id, string new_text)
	{
		m_comments.update(["_id": BsonObjectID.fromString(id)], ["$set": ["text": new_text]]);
	}

	void deleteComment(StoredComment.ID id)
	{
		m_comments.remove(["_id": BsonObjectID.fromString(id)]);
	}

	void upvote(StoredComment.ID id, StoredComment.UserID user)
	{
		static struct DQ { @name("$ne") string ne; }
		static struct Q { BsonObjectID _id; DQ downvotes; DQ author; }
		m_comments.update(Q(BsonObjectID.fromString(id), DQ(user), DQ(user)), ["$addToSet": ["upvotes": user]]);
	}

	void downvote(StoredComment.ID id, StoredComment.UserID user)
	{
		static struct DQ { @name("$ne") string ne; }
		static struct Q { BsonObjectID _id; DQ upvotes; DQ author; }
		m_comments.update(Q(BsonObjectID.fromString(id), DQ(user), DQ(user)), ["$addToSet": ["downvotes": user]]);
	}

	uint getActiveCommentCount(string topic)
	{
		import std.conv : to;
		return m_comments.count(["topic": topic, "status": "active"]).to!uint;
	}

	StoredComment[] getCommentsForTopic(string topic)
	{
		return m_comments.find!(MongoStruct!StoredComment)(["topic": topic]).map!(c => cast(StoredComment)c).array;
	}

	StoredComment[] getLatestComments()
	{
		return m_comments.find!(MongoStruct!StoredComment)().sort(["time": -1]).limit(100).map!(c => cast(StoredComment)c).array;
	}
}

deprecated alias MongoDBBackend = MongoDBCommentStore;

// Converts a string "id" field to a BsonObjectID "_id" field for storage in a MongoDB collection
struct MongoStruct(T) {
	import std.format : format;
	import std.traits : FieldTypeTuple, FieldNameTuple, getUDAs;
	import std.meta : AliasSeq;

	alias FieldTypes = FieldTypeTuple!T;
	alias FieldNames = FieldNameTuple!T;
	static assert(FieldNames[0] == "id");

	BsonObjectID _id;
	mixin(fields());

	this(T val)
	{
		if (val.id.length) _id = BsonObjectID.fromString(val.id);
		this.tupleof[1 .. $] = val.tupleof[1 .. $];
	}

	T opCast() { return T(_id == BsonObjectID.init ? "" : _id.toString(), this.tupleof[1 .. $]); }
	const(T) opCast() const { return const(T)(_id == BsonObjectID.init ? "" : _id.toString(), this.tupleof[1 .. $]); }

	static string fields()
	{
		string ret;
		foreach (i, N; FieldNames) {
			string udas;
			alias F = AliasSeq!(__traits(getMember, T, N));
			static if (getUDAs!(F, ByNameAttribute).length) udas ~= "@byName ";
			static if (getUDAs!(F, OptionalAttribute).length) udas ~= "@optional ";
			static if (N != "id")
				ret ~= format("%s FieldTypes[%s] %s;", udas, i, N);
		}
		return ret;
	}
}