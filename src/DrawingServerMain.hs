module Main (main) where


import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Data.List (intercalate)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Network
import           System.IO

import qualified Utilities as U
import Types



main :: IO ()
main = drawingServerMain

drawingServerMain :: IO ()
drawingServerMain = do

      -- Preliminaries
      bsConfig <- parseBSArgs -- TODO: Drawing server config parser
      (output, _) <- outputThread (_maxChanSize (_nodeConfig bsConfig))

      -- Node pool
      ldc <- newChan
      terminate <- newEmptyMVar -- TODO: Never actually used. Refactor node pool?
      nodePool (_poolSize bsConfig)
               (_nodeConfig bsConfig)
               ldc
               output
               terminate

      -- Bootstrap service
      printf "Starting drawing server with %d nodes"
             (_poolSize bsConfig)
      drawingServer bsConfig ldc


drawingServer = do
      -- Server to graph worker
      stg <- spawn (P.bounded (_maxChanSize config))
      forkIO (graphWorker stg)
      drawingServerLoop stg



drawingServerLoop :: PChan (To, Set To)
                  -> ???
                  -> IO ()
drawingServerLoop stg = forever $ do
      PN.acceptFork serverSock $ \(clientSock, _clientAddr) -> do
            receive clientSock >>= \case
                  Just (NeighbourList node neighbours) -> do
                        putStrLn ("Received node data from" ++ show node)
                        updateGraph node neighbours
                  Just _other_signal -> putStrLn "Invalid signal received"
                  _no_signal -> putStrLn "No signal received"




graphWorker = do
      graph <- newTVarIO Map.empty
      forever $ do
            -- Listen for new neighbour lists, add them to graph
            -- Plot graph



-- | Time in ms until a connection times out
timeoutDelay = 10^7


-- Graph consisting of a set of nodes, each having a set of neighbours.
data Graph a = Graph (Map a (Set a))

-- | Dirty string-based hacks to convert a Graph to .dot
graphToDot :: Show a => Graph a -> String
graphToDot (Graph g) = boilerplate . intercalate "\n\n" $ map (uncurry vertexToDot) $ Map.assocs g
      where boilerplate str = "\
            \digraph G {\n\
            \      node [shape = box, color = gray, fontname = \"Courier\"];\n\
            \      edge [fontname = \"Courier\"];\n\
            \      " ++ str ++ "\n\
            \}\n"

vertexToDot :: Show a => a -> Set a -> String
vertexToDot vertex edges = intercalate "\n" $ map (\x -> show vertex ++ " -> " ++ show x) $ Set.elems edges



main :: IO ()
main = do

      putStrLn "Network drawing server"

      -- Initialization
      putStrLn "Initializing"
      graph <- newTVarIO $ Graph Map.empty

      socket <- listenOn $ PortNumber 19999
      putStrLn "Starting server loop"
      drawingServerLoop socket graph

      -- TODO: Send out drawing signal to the network



drawingServerLoop :: Socket -> TVar (Graph Node) -> IO ()
drawingServerLoop socket graph = do

      (h, _, _) <- accept socket
      thread <- async $ getData h graph `finally` hClose h
      U.timeout timeoutDelay thread



-- | Gets graph data from a connected node's handle.
getData :: Handle -> TVar (Graph Node) -> IO ()
getData h graph = do

      vertex <- U.receive' h
      U.send' h OK

      let insert (v, n) (Graph g) = Graph $ Map.insert v n g
      atomically $ modifyTVar graph (insert vertex)
-- TODO: Fail when incoming data isn't a map of nodes