-- | Functions to setup and run a dedicated graphql server.
module Harness.RemoteServer
  ( run,
    generateInterpreter,
    generateQueryInterpreter,
    graphqlEndpoint,
  )
where

-------------------------------------------------------------------------------

import Control.Concurrent.Async qualified as Async
import Control.Exception.Safe (bracket)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as Lazy (ByteString)
import Data.Morpheus qualified as Morpheus (interpreter)
import Data.Morpheus.Server (RootResolverConstraint)
import Data.Morpheus.Types
  ( MUTATION,
    QUERY,
    Resolver,
    RootResolver (..),
    Undefined,
    defaultRootResolver,
  )
import Harness.Http qualified as Http
import Harness.TestEnvironment (Server (..), serverUrl)
import Hasura.Prelude
import Network.Socket qualified as Socket
import Network.Wai.Extended qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Web.Spock.Core qualified as Spock

-------------------------------------------------------------------------------

-- | This function starts a new thread with a minimal graphql server on the
-- first available port. It returns the corresponding 'Server'.
--
-- This new server serves the following routes:
--   - GET on @/@, which returns a simple 200 OK;
--   - POST on @/graphql@, which applies the function given as an argument to
--     the body of the request, and returns the resulting bytestring as JSON
--     content.
--
-- This function performs a health check, using a GET on /, to ensure that the
-- server was started correctly, and will throw an exception if the health check
-- fails. This function does NOT attempt to kill the thread in such a case,
-- which might result in a leak if the thread is still running but the server
-- fails its health check.
run ::
  -- | The 'Interpreter' that will be used to handle incoming GraphQL queries.
  --
  -- The given 'Interpreter' is applied to the body of POST requests on
  -- @/graphql@; the JSON value it returns will be the body of the server's
  -- response.
  Interpreter ->
  IO Server
run (Interpreter interpreter) = do
  let urlPrefix = "http://127.0.0.1"
  port <- bracket (Warp.openFreePort) (Socket.close . snd) (pure . fst)
  thread <- Async.async $
    Spock.runSpockNoBanner port $
      Spock.spockT id $ do
        Spock.get "/" $ do
          Spock.json $ Aeson.String "OK"
        Spock.post "/graphql" $ do
          req <- Spock.request
          body <- liftIO $ Wai.strictRequestBody req
          result <- liftIO $ interpreter body
          Spock.setHeader "Content-Type" "application/json; charset=utf-8"
          Spock.lazyBytes result
  let server = Server {port = fromIntegral port, urlPrefix, thread}
  Http.healthCheck $ serverUrl server
  pure server

-- | This function creates an 'Interpreter', able to handle incoming GraphQL
-- requests.
--
-- It takes as arguments two 'Morpheus.Resolver's: one that represents how to
-- handle incoming queries, and one that does the same for mutations. In most
-- cases, those two "resolvers" will respectively be the @Query@ and @Mutation@
-- data types that are generated by a call to 'Morpheus.importGQLDocument' or
-- from an inline 'Morpheus.gqlDocument'. This function is generic, as those
-- types will be different in each test file.
--
-- NOTE: this function does not expect a resolver for subscriptions, and the
-- resulting 'Interpreter' will therefore reject all incoming subscriptions.
--
-- For example, given the following schema:
--
--     type Point {
--       x: Int!,
--       y: Int!
--     }
--
--     type Query {
--       foo: Point!
--     }
--
--     type Mutation {
--       bar(argName: String): String
--     }
--
-- A call to 'Morpheus.gqlDocument' with said schema would generate the
-- following data types:
--
--     data Point m = Point
--       { x :: m Int
--       , y :: m Int
--       }
--
--     data Query m = Query
--       { foo :: m (Point m)
--       }
--
--     data Mutation m = Mutation
--       { bar :: Arg "argName" (Maybe Text) -> m (Maybe Text)
--       }
--
-- This would therefore be a valid call to 'generateInterpreter':
--
--     let
--       -- matches the "foo" field of Query: takes no argument, returns a
--       -- non-nullable Point
--       foo :: Monad m => m (Point m)
--       foo = pure Point
--         { x = pure 1
--         , y = pure 2
--         }
--       -- matches the "bar" field of Mutation: takes a nullable String and
--       -- returns a nullable String, both represented as a @Maybe Text@.
--       bar :: Monad m => Arg "argName" (Maybe Text) -> m (Maybe Text)
--       bar (Arg argName) = pure argName
--     in
--       generateInterpreter (Query {foo}) (Mutation {bar})
--
-- Each field function encodes how to resolve a field from an incoming request,
-- in an given monad; 'generateIntepreter' expects all results to be in a
-- Morpheus monad on top of 'IO', allowing for side-effects if required. For
-- queries, it will often be enough to implement fields as pure transfomations
-- from their arguments, as shown above.
--
-- For further reading, Morpheus' documentation shows what the generated types
-- for a schema look like, and has an example project:
--   - https://morpheusgraphql.com/server
--   - https://github.com/morpheusgraphql/mythology-api/blob/master/src/Mythology/API.hs
generateInterpreter ::
  forall query mutation.
  RootResolverConstraint IO () query mutation Undefined =>
  query (Resolver QUERY () IO) ->
  mutation (Resolver MUTATION () IO) ->
  Interpreter
generateInterpreter queryResolver mutationResolver =
  Interpreter $
    Morpheus.interpreter $
      defaultRootResolver {queryResolver, mutationResolver}

-- | This function is similar to 'generateInterpreter', but only expects a
-- resolver for queries. The resulting 'Interpreter' only supports queries, and
-- handles neither mutations nor subscriptions.
generateQueryInterpreter ::
  forall query.
  RootResolverConstraint IO () query Undefined Undefined =>
  query (Resolver QUERY () IO) ->
  Interpreter
generateQueryInterpreter queryResolver =
  Interpreter $ Morpheus.interpreter $ defaultRootResolver {queryResolver}

-- | Extracts the full GraphQL endpoint URL from a given remote server's 'Server'.
--
-- @
--   > graphqlEndpoint (Server 8080 "http://localhost" someThreadId)
--   "http://localhost:8080/graphql"
-- @
--
-- NOTE: the resulting endpoint is only relevant for a 'Server' started by this
-- module's 'run' function; the GraphQL engine doesn't have a /graphql endoint.
graphqlEndpoint :: Server -> String
graphqlEndpoint server = serverUrl server ++ "/graphql"

-------------------------------------------------------------------------------

-- | An interpreter is a transformation function, applied to an incoming GraphQL
-- query, used to generate the resulting JSON answer that will be returned by
-- the server. While conceptually it expects a JSON object representing the
-- GraphQL query and returns a JSON value, it is actually represented internally
-- as a function that directly operates on 'Lazy.ByteString's.
--
-- That type is not exported, and the only possible way of creating an
-- 'Interpreter' is via 'generateInterpreter' and 'generateQueryInterpreter'.
newtype Interpreter = Interpreter (Lazy.ByteString -> IO Lazy.ByteString)
