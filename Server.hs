-- | The server is the main part of a node. It accepts incoming requests, and
--   distributes the responses to the clients.

{-# LANGUAGE LambdaCase #-}

-- TODO: Handle pattern mismatches on all of the handler functions. Those
--       branches should never be reached, but just to be safe there should be
--       error messages anyway.

module Server (
      serverLoop
) where

import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Exception (finally, bracket)
import           Control.Monad
import           Data.Functor
import           Network
import           System.IO
import           System.Random
import           Text.Printf
import qualified Data.Map               as Map
import qualified Data.Set               as Set


import Types
import Utilities
import Client








-- | Forks off a worker for each incoming connection.
serverLoop :: Socket
           -> Environment
           -> IO ()
serverLoop socket env = forever $ do

      -- NB: h is closed by the worker, bracketing here would close it
      --     immediately after forking
      (h, host, port) <- accept socket
      let fromNode = Node host port
      void.async $ worker env h fromNode





-- | Handles an incoming connection: Pass incoming work orders on to clients,
--   print chat messages etc.
--   (The first parameter is the same as in the result of Network.accept.)
worker :: Environment
       -> Handle
       -> Node
       -> IO ()
worker env h from = (`finally` hClose h) $ do

      -- TODO: Ignore signals sent by nodes not registered as upstream.
      --       Open issues:
      --         - Do this here or in the server loop?
      --         - How do the ignored nodes find out they're being ignored? --> Solution: timeouts

      -- TODO: Housekeeping to delete already handled messages

      -- TODO: Error handling: What to do if rubbish data comes in?
      --       -> Respond error, kill worker
      receive h >>= \case
            Normal  normal  -> normalHandler  env h from normal
            Special special -> specialHandler env h from special



-- | Handler for normally issued normal signals, as sent by an upstream
--   neighbour. This handler will check whether the sender is a valid upstream
--   neighbour, update timestamps etc. (An example for an abnormally issued
--   normal signal is one encapsulated in a bootstrap request, which will be
--   processed differently.)
normalHandler :: Environment
              -> Handle       -- ^ Data channel
              -> Node         -- ^ Signal origin
              -> NormalSignal -- ^ Signal type
              -> IO ()

normalHandler env h from signal = do

      -- Check whether contacting node is valid upstream
      allowed <- atomically $ Map.member from <$> readTVar (_upstream env)

      if allowed
            then do normalHandler' env h from signal
                    -- Update "last heard of" timestamp. Note that this will not
                    -- add a valid return address (but some address the incoming
                    -- connection happens to have)!
                    makeTimestamp >>= atomically . updateKnownBy env from
            else do send h Ignore
                    atomically . toIO env Debug . putStrLn $
                          "Illegally contacted by " ++ show from ++ "; ignoring"





-- | Handler for any normal signal. Does not check whether the sender is legal,
--   and should therefore only be invoked from within other handlers making sure
--   of that, see normalHandler and specialHandler.
normalHandler' :: Environment
              -> Handle       -- ^ Data channel
              -> Node         -- ^ Signal origin
              -> NormalSignal -- ^ Signal type
              -> IO ()

normalHandler' env h from signal = send h OK >> case signal of
      TextMessage {}    -> floodMessage      env signal
      ShuttingDown node -> shuttingDown      env node
      IAddedYou         -> iAddedYouReceived env from
      AddMe             -> addMeReceived     env from
      EdgeRequest {}    -> edgeBounce        env signal
      KeepAlive         -> keepAlive         env from




specialHandler :: Environment
               -> Handle        -- ^ Data channel
               -> Node          -- ^ Signal origin
               -> SpecialSignal -- ^ Signal type
               -> IO ()

specialHandler env h from signal = do

      -- TODO: Check whether contact is a valid, e.g. if it's a bootstrap server

      case signal of
            BootstrapHelper sig -> normalHandler' env h from sig
            BootstrapRequest {} -> send h Error >> bootstrapRequest env
            YourHostIs {}       -> send h Error >> yourHostIs       env




-- | A node should never receive a YourHostIs signal unless it issued
--   Bootstrap. In case it gets one anyway, this function is called.
yourHostIs :: Environment -> IO ()
yourHostIs env = do
      atomically . toIO env Debug . putStrLn $
            "BootstrapRequest signal received on a normal server, ignoring"




bootstrapRequest :: Environment -> IO ()
bootstrapRequest env = do
      atomically . toIO env Debug . putStrLn $
            "BootstrapRequest signal received on a normal server, ignoring"




-- | Acknowledges an incoming KeepAlive signal, which is effectively a no-op,
--   apart from that it (like any other signal) refreshes the "last heard of
--   timestamp".
keepAlive :: Environment -> Node -> IO ()
keepAlive env origin = do
      atomically . toIO env Chatty . putStrLn $
            "KeepAlive signal received from " ++ show origin









-- | Sends a message to the printer thread
floodMessage :: Environment
             -> NormalSignal
             -> IO ()
floodMessage env signal = do

      -- Only process the message if it hasn't been processed already
      process <- atomically $
            Set.member signal <$> readTVar (_handledQueries env)

      when process $ atomically $ do

            -- Add signal to the list of already handled ones
            modifyTVar (_handledQueries env) (Set.insert signal)

            -- Print message on the current node
            let (TextMessage _timestamp message) = signal -- TODO: Handle pattern mismatch
            toIO env Quiet $ putStrLn message

            -- Propagate message on to all clients
            writeTChan (_stc env) signal

      -- Keep the connection alive, e.g. to get more messages
      -- from that node.





-- | Inserts or updates the timestamp in the "last heard of" database. Does
--   nothing if the node isn't registered upstream.
updateKnownBy :: Environment
              -> Node
              -> Timestamp
              -> STM ()
updateKnownBy env node timestamp = modifyTVar (_upstream env) $
                                               Map.adjust (const timestamp) node





-- | Remove the issuing node from the database
shuttingDown :: Environment
             -> Node
             -> IO ()
shuttingDown env node = do

      atomically $ toIO env Debug $ printf "Shutdown notice from %s:%s"
                                           (show $ _host node)
                                           (show $ _port node)

      -- Remove from lists of known nodes and nodes known by
      atomically $ modifyTVar (_upstream env) (Map.delete node)

      -- Just in case there is also a downstream connection to the same node,
      -- kill that one as well
      downstream <- atomically $ Map.lookup node <$> readTVar (_downstream env)
      maybe (return ()) (cancel._clientAsync) downstream
      atomically $ modifyTVar (_downstream env) (Map.delete node)










-- | A node signals that it has added the current node to its pool. This happens
--   at the end of a neighbour search.
--
--   This should be the first signal the current node receives from another node
--   choosing it as its new neighbour.
iAddedYou :: Environment
          -> Node
          -> IO ()
iAddedYou env node = do
      timestamp <- makeTimestamp
      atomically $ do
            modifyTVar (_upstream env) (Map.insert node timestamp)
            toIO env Debug $ putStrLn $ "New upstream neighbour: " ++ show node
       -- Let's not close the door in front of our new friend :-)






-- | Bounces EdgeRequests through the network in order to make new connections.
--   The idea behind this behaviour is that a new connection should be as long
--   as possible, i.e. ideally establish a link to an entirely different part of
--   the network, which prevents clustering.
--
--   When a node receives an incoming ("Hey, I'm here, please make me your
--   neighbour") or outgoing ("I need more neighbours") request, it either
--   accepts it or bounces the request on to a downstream neighbour that repeats
--   the process. The procedure has two phases:
--
--     1. In phase 1, a counter will keep track of how many bounces have
--        occurred. For example, a signal may contain the information "bounce
--        me 5 times". This makes sure the signal traverses the network a
--        certain amount, so the signal doesn't just stay in the issuing node's
--        neighbourhood.
--        Because of its definite "bounce on" nature, these are also referred to
--        as "hard bounces".
--
--     2. Phase 2 is like phase 1, but instead of a counter, there's a denial
--        probability. If there's room and the node rolls to keep the signal,
--        it will do what its contents say. If there is no room or the node
--        rolls to deny the request, it is bounced on once again, but with a
--        reduced denial probability. This leads to an approximately
--        exponentially distributed bounce-on-length in phase 2. This solves the
--        issue of having a long chain of nodes, where only having phase one
--        would reach the same node every time.
--        Because of the probabilistic travelling distance of these bounces,
--        they are also referred to as "soft bounces".

edgeBounce :: Environment
           -> NormalSignal
           -> IO ()

-- Phase 1: Left value, bounce on.
edgeBounce env (EdgeRequest origin (EdgeData dir (Left n))) = do

      let buildSignal = EdgeRequest origin . EdgeData dir
      atomically $ do
            writeTBQueue (_st1c env) . buildSignal $ case n of
                  0 -> Right (_acceptP $ _config env)
                  k -> Left $ min (k - 1) (_bounces $ _config env)
                       -- ^ Cap the number of hard bounces with the current
                       -- node's configuration to prevent "maxBound bounces
                       -- left" attacks
            toIO env Chatty $ printf "Bounced %s (%d left)" (show origin) n



-- Phase 2: either accept or bounce on with adjusted acceptance
-- probability.
--
-- (Note that bouncing on always decreases the denial probability, even in case
-- the reason was not enough room.)
edgeBounce env (EdgeRequest origin (EdgeData dir (Right p))) = do

      -- Build "bounce on" action to relay signal if necessary
      let buildSignal = EdgeRequest origin . EdgeData dir . Right
          p' = max p $ (_acceptP._config) env
          -- ^ The relayed acceptance probability is at least as high as the
          -- one the relaying node uses. This prevents "small p" attacks
          -- that bounce indefinitely.
          bounceOn = atomically . writeTBQueue (_st1c env) $ buildSignal p'

      -- Checks whether there's still room for another entry. The TVar can
      -- either be the set of known or "known by" nodes.
      let threshold = (_maxNeighbours._config) env
          isRoomIn tVar = atomically $
                (< threshold) . fromIntegral . Map.size <$> readTVar tVar

      -- Make sure not to connect to itself or to already known nodes
      allowed <- isAllowed env dir origin

      -- Roll whether to accept the query first, then check whether there's
      -- room. In case of failure, bounce on.
      acceptEdge <- (> p) <$> randomRIO (0,1)
      case (allowed && acceptEdge, dir) of
            (False ,_) -> do let msg = "Request denied, bouncing"
                             atomically . toIO env Debug $ putStrLn msg
                             bounceOn
            (_, Outgoing) -> do -- TODO: Sub-method, running off screen here
                  isRoom <- isRoomIn (_downstream env)
                  if isRoom then acceptOutgoingRequest env origin
                            else do let msg = "No room for incoming " ++
                                              "connections, bouncing"
                                    atomically . toIO env Chatty $ putStrLn msg
                                    bounceOn
            (_, Incoming) -> do -- TODO: Sub-method, running off screen here
                  isRoom <- isRoomIn (_upstream env)
                  if isRoom then forkNewClient env origin -- TODO: Message
                            else do let msg = "No room for outgoing " ++
                                              "connections, bouncing"
                                    atomically . toIO env Chatty $ putStrLn msg
                                    bounceOn




-- Bad signal received. "Else" case of the function's pattern.
edgeBounce env signal = do
      atomically $ toIO env Debug $ printf ("Signal %s received by edgeBounce;"
                                    ++ "this should never happen") (show signal)




-- | Sent as a confirmation message when a Outgoing request issued by another
--   node was accepted by this node. In other words, this function sends a "yes,
--   you may add me as your neighbour".
acceptOutgoingRequest :: Environment -> Node -> IO ()
acceptOutgoingRequest env origin = do
      timestamp <- makeTimestamp
      bracket (connectToNode origin) hClose $ \h -> do
            send h AddMe
            atomically $ updateKnownBy env origin timestamp



-- | Invoked on an incoming "Outgoing request successful" signal, i.e. after
--   sending out a Outgoing EdgeRequest, another node has given this node the
--   permission to add it as a downstream neighbour. Spawns a new worker
--   connecting to the accepting node.
addMeReceived :: Environment -> Node -> IO ()
addMeReceived env node = forkNewClient env node


-- | IAddedYou is sent to a new downstream neighbour as the result of a
--   successful Incoming request. When received, this handler does the
--   bookkeeping for the new incoming connection.
iAddedYouReceived :: Environment -> Node -> IO ()
iAddedYouReceived env node = do
      timestamp <- makeTimestamp
      atomically $ updateKnownBy env node timestamp


      -- TODO: Check whether the previous 3 functions get all the directions right (i.e. do what they should)!




-- | Checks whether a connection from/to origin is allowed. A node must not
--   connect to itself or to known neighbours multiple times.
isAllowed :: Environment -> Direction -> Node -> IO Bool
isAllowed env dir origin = do

      -- Don't connecto to yourself
      let isSelf = origin == _self env

      -- 1. The origin node requesting an incoming connection is already
      --    downstream
      -- 2. The origin node requesting an outgoing connection is already
      --    upstream
      let isInDatabase db = atomically $ Map.member origin <$> readTVar db
      isAlreadyKnown <- case dir of
            Incoming -> isInDatabase (_downstream env)
            Outgoing -> isInDatabase (_upstream env)

      return $ isSelf || isAlreadyKnown

